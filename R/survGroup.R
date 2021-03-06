#' Predict genesets associated with survival
#' @param maf an \code{\link{MAF}} object generated by \code{\link{read.maf}}
#' @param top If genes is \code{NULL} by default used top 20 genes
#' @param genes Manual set of genes
#' @param geneSetSize Default 2
#' @param minSamples minimum number of samples to be mutated to be considered for analysis. Default 5
#' @param clinicalData dataframe containing events and time to events. Default looks for clinical data in annotation slot of \code{\link{MAF}}.
#' @param time column name contining time in \code{clinicalData}
#' @param Status column name containing status of patients in \code{clinicalData}. must be logical or numeric. e.g, TRUE or FALSE, 1 or 0.
#' @param verbose Default TRUE
#' @export
#' @examples
#' laml.maf <- system.file("extdata", "tcga_laml.maf.gz", package = "maftools")
#' laml.clin <- system.file("extdata", "tcga_laml_annot.tsv", package = "maftools")
#' laml <- read.maf(maf = laml.maf,  clinicalData = laml.clin)
#' survGroup(maf = laml, top = 20, geneSetSize = 1, time = "days_to_last_followup", Status = "Overall_Survival_Status")

survGroup = function(maf, top = 20, genes = NULL, geneSetSize = 2, minSamples = 5, clinicalData = NULL, time = "Time",
                     Status = "Status", verbose = TRUE){

  if(is.null(genes)){
    genes = getGeneSummary(x = maf)[1:top, Hugo_Symbol]
  }

  if(length(genes) < 2){
    stop("Minimum two genes required!")
  }

  genesCombn = combn(x = genes, m = geneSetSize)

  if(verbose){
    cat("------------------\n")
    cat(paste0("genes: ", length(genes), "\n"))
    cat(paste0("geneset size: ", geneSetSize, "\n"))
    cat(paste0(ncol(genesCombn), " combinations\n"))
  }

  if(is.null(clinicalData)){
    if(verbose){
      message("Looking for clinical data in annoatation slot of MAF..")
    }

    clinicalData = data.table::copy(getClinicalData(x = maf))
    clinicalData = data.table::setDT(clinicalData)
  }else{
    clinicalData = data.table::setDT(clinicalData)
  }

  if(!"Tumor_Sample_Barcode" %in% colnames(clinicalData)){
    print(colnames(clinicalData))
    stop("Column Tumo_Sample_Barcode not found in clinical data. Check column names and rename it to Tumo_Sample_Barcode if necessary.")
  }

  if(length(colnames(clinicalData)[colnames(clinicalData) %in% time]) == 0){
    print(colnames(clinicalData))
    stop(paste0(time, " not found in clinicalData. Use argument time to povide column name containing time to event."))
  }else{
    colnames(clinicalData)[colnames(clinicalData) %in% time] = 'Time'
  }

  if(length(colnames(clinicalData)[colnames(clinicalData) %in% Status]) == 0){
    print(colnames(clinicalData))
    stop(paste0(Status, " not found in clinicalData. Use argument Status to povide column name containing events (Dead or Alive)."))
  }else{
    colnames(clinicalData)[colnames(clinicalData) %in% Status] = 'Status'
  }

  clinicalData$Time = suppressWarnings(as.numeric(as.character(clinicalData$Time)) )
  clinicalData$Status = suppressWarnings(as.integer(clinicalData$Status))
  clinicalData$Time = ifelse(test = is.infinite(clinicalData$Time), yes = NA, no = clinicalData$Time)
  if(nrow(clinicalData[!is.na(Time)][!is.na(Status)]) < nrow(clinicalData)){
    message(paste0("Removed ", nrow(clinicalData) - nrow(clinicalData[!is.na(Time)][!is.na(Status)]),
                   " samples with NA's"))
    clinicalData = clinicalData[!is.na(Time)][!is.na(Status)]
  }

  om = createOncoMatrix(m = maf, g = genes)
  all.tsbs = levels(getSampleSummary(x = maf)[,Tumor_Sample_Barcode])

  mutMat = t(om$numericMatrix)
  missing.tsbs = all.tsbs[!all.tsbs %in% rownames(mutMat)]

  if(nrow(mutMat) < 2){
    stop("Minimum two genes required!")
  }
  mutMat[mutMat > 0 ] = 1

  res = lapply(seq_along(1:ncol(genesCombn)), function(i){
    x = genesCombn[,i]
    mm = mutMat[,x, drop = FALSE]
    genesTSB = names(which(rowSums(mm) == geneSetSize))
    if(length(genesTSB) >= minSamples){
      if(verbose){
        cat("Geneset: ", paste0(x, collapse = ","), "[N=", length(genesTSB),"]\n")
      }
      surv.dat = run_surv(cd = clinicalData, tsbs = genesTSB)
    }else{
      surv.dat = NULL
    }
    surv.dat
  })
  names(res) = apply(genesCombn, 2, paste, collapse = '_')
  res = data.table::rbindlist(l = res, idcol = "Gene_combination")
  res = res[order(P_value, decreasing = FALSE)]
  res
}

run_surv = function(cd, tsbs){
  groupNames = c("Mutant", "WT")
  col = c('maroon', 'royalblue')
  cd$Group = ifelse(test = cd$Tumor_Sample_Barcode %in% tsbs, yes = groupNames[1], no = groupNames[2])

  surv.km = survival::survfit(formula = survival::Surv(time = Time, event = Status) ~ Group, data = cd, conf.type = "log-log")
  res = summary(surv.km)

  surv.diff = survival::survdiff(formula = survival::Surv(time = Time, event = Status) ~ Group, data = cd)
  surv.diff.pval = signif(1 - pchisq(surv.diff$chisq, length(surv.diff$n) - 1), digits = 3)

  surv.cox = survival::coxph(formula = survival::Surv(time = Time, event = Status) ~ Group, data = cd)
  hr = signif(1/exp(stats::coef(surv.cox)), digits = 3)

  #surv.dat = data.table::data.table(Group = res$strata, Time = res$time, survProb = res$surv, survUp = res$upper, survLower = res$lower)
  #surv.dat$Group = gsub(pattern = 'Group=', replacement = '', x = surv.dat$Group)
  surv.dat = data.table::data.table(P_value = surv.diff.pval, hr = hr, WT = nrow(cd[Group == "WT"]), Mutant = nrow(cd[Group == "Mutant"]))
}
