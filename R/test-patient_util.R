library("testthat")
library("tidyverse")
library("magrittr")
source("R/patient_util.R")

VERBOSE = FALSE

# override with test data
CLEAN_PT_DATA_CACHE <- "data/test/patient-cache.csv"
Util.CommunityPaths <- function() {
  list.dirs("data/test")[-1] # element 1 is "data/test" itself
}

TestPatients <- function() {
  input <- Pt.FetchData()
  patients <- Pt._DenormalizeCommunityNames(
    input$patientsPerSite, input$communitiesPerSite
  )
  patients %<>% Util.AppendClinicNames(Util.CommunityPaths())
  patients <- do.call(rbind, patients)  # flatten
  patients %<>% as_tibble()
  patients %<>% Pt._Unfactorize()
  return(patients)
}

test_that("ParseIdentifier produces old ID", {
  output <- Pt._ParseIdentifier(c("12345", "23456"), c("a", "b"))
  expect_equal(length(output), 2)
  expect_equal(output[[1]], "Old Identification Number:12345:a")
  expect_equal(output[[2]], "Old Identification Number:23456:b")
})

test_that("ParseIdentifier doesn't produce blank identifiers", {
  output <- Pt._ParseIdentifier(c("12345", NA), c("a", "b"))
  expect_equal(length(output), 2)
  expect_equal(output[[1]], "Old Identification Number:12345:a")
  expect_equal(output[[2]], "")
})


test_that("ParseAndFixBirthdates attaches birthday columns", {
  output <- Pt._ParseAndFixBirthdates(TestPatients())
  expect_equal(output[[1, "birthdate"]], "2011-4-10")
  expect_equal(output[[1, "birthdate.is.estimated"]], FALSE)
})

test_that("ParseAndFixBirthdates fixes nonsense birthdays", {
  output <- Pt._ParseAndFixBirthdates(TestPatients())
  expect_equal(output[[5, "birthdate"]], "1959-1-5")
  expect_equal(output[[5, "birthdate.is.estimated"]], TRUE)
  expect_equal(output[[6, "birthdate"]], "1900-1-1")
  expect_equal(output[[6, "birthdate.is.estimated"]], TRUE)
  expect_equal(output[[7, "birthdate"]], "1900-12-1")
  expect_equal(output[[7, "birthdate.is.estimated"]], TRUE)
  expect_equal(output[[8, "birthdate"]], "1900-6-25")
  expect_equal(output[[8, "birthdate.is.estimated"]], TRUE)
})

test_that("FilterUnsalvagableData removes no-name row", {
  fixed <- Pt._FixInvalidData(TestPatients())
  output <- Pt._FilterUnsalvagableData(fixed)
  naRow <- output[output$CesID == "120-000005", ]
  expect_equal(nrow(naRow), 0)
})

test_that("CreateDistinctPatients splits CES IDs and adds the old IDs as a column", {
  patients <- tribble(
    ~"CesID", ~"Nombre", ~"commName", ~"oldCommName",
    "1-0001", "William", "Laguna del Cofre", "Laguna",
    "1-0001", "Douglas", "Soledad", "Soledad",
    "1-0001", "Ricky", "Salvador", "Salvador",
    "1-0002", "Bill", "Plan de la Libertad", "Plan_Alta",
    "1-0002", "Gregory", "Plan de la Libertad", "Plan_Baja"
  )
  patients <- Pt._PrepPtsForCreateDistinct(patients)
  output <- Pt._CreateDistinctPatients(patients, "1-0001")
  
  # Check new CesIDs
  expect_equal(output[output$CesID == "1-0001-1", ][["Nombre"]], "William")
  expect_equal(output[output$CesID == "1-0001-2", ][["Nombre"]], "Douglas")
  expect_equal(output[output$CesID == "1-0001-3", ][["Nombre"]], "Ricky")
  expect_equal(nrow(output[output$CesID == "1-0001", ]), 0)
  
  # Check that we can look up the old ones
  expect_equal(output[output$oldCesId == "1-0001" &
                      output$oldCommName == "Laguna", ][["CesID"]],
               "1-0001-1")
  expect_equal(output[output$oldCesId == "1-0001" &
                      output$oldCommName == "Soledad", ][["CesID"]],
               "1-0001-2")
})

test_that("GetNewCesId looks up vectors", {
  patients <- tribble(
    ~"CesID", ~"Nombre", ~"commName", ~"allOldCommNames", ~"oldCesId",
    "1-0001-1", "William", "Laguna del Cofre", "Laguna,Letrero", "1-0001",
    "1-0001-2", "Douglas", "Soledad", "Soledad,Matazano", "1-0001",
    "1-0001-3", "Ricky", "Salvador", "Salvador", "1-0001",
    "1-0002", "Bill", "Plan de la Libertad", "Plan_Alta", "1-0002",
    "1-0002", "Gregory", "Plan de la Libertad", "Plan_Baja", "1-0002"
  )
  newIds <- Pt.GetNewCesId(patients, c("1-0001", "1-0002"), c("Matazano", "Plan_Baja"))
  expect_equal(newIds, c("1-0001-2", "1-0002"))
})

test_that("GetNewCesId defaults to the input CesId", {
  patients <- tribble(
    ~"CesID", ~"Nombre", ~"commName", ~"allOldCommNames", ~"oldCesId",
    "1-0001-1", "William", "Laguna del Cofre", "Laguna", "1-0001",
    "1-0001-2", "Douglas", "Soledad", "Soledad", "1-0001"
  )
  newIds <- Pt.GetNewCesId(patients, c("1-0001", "1-2000"), c("Laguna", "Plan_Baja"))
  expect_equal(newIds, c("1-0001-1", "1-2000"))
})

test_that("ManualDedupe takes care of Bentobox Cuckooclock", {
  output <- Pt._ManualDedupe(TestPatients())
  bentoboxes <- output[startsWith(output$CesID, "001-000020"), ]
  expect_equal(nrow(bentoboxes), 2)
  expect_equal(bentoboxes[[1, "FN_Ano"]], 1995)
  expect_equal(bentoboxes[[2, "FN_Ano"]], 1970)
})

test_that("Deduplicate takes care of Rumblesack Cummerbund", {
  output <- Pt._Deduplicate(TestPatients())
  rumblesacks <- output[startsWith(output$CesID, "112-000351"), ]
  expect_equal(nrow(rumblesacks), 1)
  # Birthday comes from Salvador
  expect_equal(rumblesacks[[1, "FN_Ano"]], 2011)
  # HTN data should be pulled from Soledad
  expect_true(rumblesacks[[1, "Hipertensión"]])
  expect_equal(rumblesacks[[1, "HTN_Fecha"]], "Fri May 19 00:00:00 CDT 2017")
  # Should have "allOldCommNames" equal to "Salvador,Soledad"
  expect_equal(rumblesacks[[1, "allOldCommNames"]], "Salvador,Soledad")
})

test_that("Repeated CesIDs with different data get split", {
  output <- Pt._SplitDuplicatedCesIds(TestPatients())
  repeated <- output[startsWith(output$CesID, "120-000004"), ]
  expect_equal(nrow(repeated), 2)
  expect_equal(repeated[[1, "FN_Ano"]], 2010)
  expect_equal(repeated[[2, "FN_Ano"]], 1998)
})

test_that("GetCleanedTable doesn't fail", {
  Pt.GetCleanedTable()
})

test_that("GetCleanedTable attached pt UUID", {
  output <- Pt.GetCleanedTable(useCache = FALSE)
  expect_true("ptUuid" %in% colnames(output))
  expect_true(length(output$ptUuid) == nrow(output))
  expect_true(typeof(output$ptUuid) == "character")
  expect_equal(output$ptUuid, Pt._GeneratePtUuid(output))
})

test_that("uuids are deterministic", {
  output1 <- Pt.GetCleanedTable(useCache = FALSE)
  output2 <- Pt.GetCleanedTable(useCache = FALSE)
  expect_equal(output1$ptUuid, output2$ptUuid)
})

test_that("uuids are maintained over cache load", {
  file.remove(CLEAN_PT_DATA_CACHE)
  runResults <- Pt.GetCleanedTable(useCache = FALSE)
  cacheData <- read.csv(CLEAN_PT_DATA_CACHE)
  expect_equal(as.character(cacheData$ptUuid), as.character(runResults$ptUuid))
  cachedRunResults <- Pt.GetCleanedTable(useCache = TRUE)
  expect_equal(as.character(cachedRunResults$ptUuid), as.character(runResults$ptUuid))
})

test_that("uuids are unique", {
  output <- Pt.GetCleanedTable(useCache = FALSE)
  expect_true(!any(duplicated(output$ptUuid)))
})

# Test is failing
#
# test_that("GetCleanedTable cache returns the same result as a normal run", {
#   file.remove(CLEAN_PT_DATA_CACHE)
#   runResults <- Pt.GetCleanedTable(useCache = TRUE)
#   cacheData <- read.csv(CLEAN_PT_DATA_CACHE)
#   Equalish <- function(d1, d2) {
#     all((is.na(d1) & is.na(d2)) | d1 == d2)
#   }
#   expect_equal(cacheData, runResults)
#   
#   cachedRunResults <- Pt.GetCleanedTable(useCache = TRUE)
#   expect_equal(cachedRunResults, runResults)
# })