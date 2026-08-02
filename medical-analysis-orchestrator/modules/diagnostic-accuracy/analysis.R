run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config,"diagnostic-accuracy")
  outcome <- as.character(parameters$outcome %||% "")
  event_level <- as.character(parameters$event_level %||% "")
  markers <- unique(as.character(parameters$markers %||% character()))
  thresholds <- parameters$thresholds %||% list()
  direction <- as.character(parameters$direction %||% "auto")
  confidence_level <- as.numeric(parameters$confidence_level %||% .95)
  if(!nzchar(outcome)||!nzchar(event_level)||!length(markers)) stop("诊断准确性分析必须指定结局、阳性事件和至少一个标志物。",call.=FALSE)
  assert_columns(context$data,c(outcome,markers),"diagnostic-accuracy")
  subset <- analysis_subset(context$data,c(outcome,markers))
  data <- subset$data
  levels <- unique(as.character(data[[outcome]]))
  if(length(levels)!=2L||!event_level%in%levels) stop("诊断结局必须恰有两个水平且阳性事件水平存在。",call.=FALSE)
  truth <- factor(as.character(data[[outcome]]),levels=c(setdiff(levels,event_level),event_level))
  positive_n <- sum(truth==event_level); negative_n <- sum(truth!=event_level)
  if(min(positive_n,negative_n)<10L) stop("阳性或阴性样本少于 10，不能稳定估计诊断准确性。",call.=FALSE)
  roc_objects <- list(); auc_rows <- list(); threshold_rows <- list(); warnings <- character()
  for(marker in markers){
    values <- safe_numeric(data[[marker]])
    if(any(!is.finite(values))||stats::sd(values)==0) stop("诊断标志物必须为有变异的数值变量：",marker,call.=FALSE)
    roc <- pROC::roc(truth,values,levels=levels(truth),direction=direction,quiet=TRUE,ci=FALSE)
    roc_objects[[marker]] <- roc
    auc_ci <- as.numeric(pROC::ci.auc(roc,conf.level=confidence_level))
    auc_rows[[length(auc_rows)+1L]] <- data.frame(marker=marker,n=nrow(data),positive=positive_n,negative=negative_n,auc=as.numeric(pROC::auc(roc)),conf_low=auc_ci[1],conf_high=auc_ci[3],direction=roc$direction,stringsAsFactors=FALSE)
    confirmed_threshold <- thresholds[[marker]]
    threshold_source <- if(is.null(confirmed_threshold)) "Youden（数据驱动）" else "方案预先指定"
    coordinate <- if(is.null(confirmed_threshold)) {
      pROC::coords(roc,"best",best.method="youden",ret=c("threshold","sensitivity","specificity","ppv","npv"),transpose=FALSE)
    } else {
      pROC::coords(roc,x=as.numeric(confirmed_threshold),input="threshold",ret=c("threshold","sensitivity","specificity","ppv","npv"),transpose=FALSE)
    }
    threshold_rows[[length(threshold_rows)+1L]] <- data.frame(
      marker=marker,threshold=as.numeric(coordinate["threshold"]),threshold_source=threshold_source,
      sensitivity=as.numeric(coordinate["sensitivity"]),specificity=as.numeric(coordinate["specificity"]),
      ppv=as.numeric(coordinate["ppv"]),npv=as.numeric(coordinate["npv"]),
      positive_likelihood_ratio=as.numeric(coordinate["sensitivity"])/max(1e-12,1-as.numeric(coordinate["specificity"])),negative_likelihood_ratio=(1-as.numeric(coordinate["sensitivity"]))/max(1e-12,as.numeric(coordinate["specificity"])),stringsAsFactors=FALSE
    )
  }
  auc_table <- do.call(rbind,auc_rows); threshold_table <- do.call(rbind,threshold_rows)
  comparisons <- list()
  if(length(markers)>=2L){
    for(pair in utils::combn(markers,2L,simplify=FALSE)){
      test <- pROC::roc.test(roc_objects[[pair[1]]],roc_objects[[pair[2]]],method="delong",paired=TRUE)
      comparisons[[length(comparisons)+1L]] <- data.frame(marker_1=pair[1],marker_2=pair[2],auc_difference=as.numeric(pROC::auc(roc_objects[[pair[1]]])-pROC::auc(roc_objects[[pair[2]]])),method="DeLong",statistic=unname(test$statistic),p_value=test$p.value,stringsAsFactors=FALSE)
    }
  }
  comparison_table <- if(length(comparisons))do.call(rbind,comparisons) else data.frame(marker_1=character(),marker_2=character(),auc_difference=double(),method=character(),statistic=double(),p_value=double())
  if(nrow(comparison_table)) comparison_table$p_adjusted <- stats::p.adjust(comparison_table$p_value,method=as.character(config$data_handling$multiple_testing$method %||% "holm")) else comparison_table$p_adjusted <- numeric()
  source_rows <- list()
  for(marker in markers){
    coords <- pROC::coords(roc_objects[[marker]],"all",ret=c("threshold","sensitivity","specificity"),transpose=FALSE)
    coords <- as.data.frame(coords); coords$marker <- marker; coords$false_positive_rate <- 1-coords$specificity
    source_rows[[length(source_rows)+1L]] <- coords[,c("marker","threshold","false_positive_rate","sensitivity")]
  }
  figure_source <- do.call(rbind,source_rows)
  source_path <- write_figure_source_data(context,"diagnostic_roc",figure_source)
  plot_roc <- function(){
    palette <- medical_figure_palette()
    colors <- medical_figure_colors(length(markers))
    first <- TRUE
    for(i in seq_along(markers)){
      roc <- roc_objects[[markers[i]]]
      if(first){graphics::plot(roc,legacy.axes=TRUE,col=colors[i],lwd=2,main="ROC 曲线比较");first<-FALSE}else pROC::plot.roc(roc,add=TRUE,col=colors[i],lwd=2)
    }
    graphics::abline(0,1,lty=2,col=palette[["neutral"]]);graphics::legend("bottomright",legend=paste0(markers," AUC=",sprintf("%.3f",auc_table$auc)),col=colors,lwd=2,bty="n")
  }
  exports <- export_r_figure(config,context,"01_ROC曲线比较",plot_roc,width_mm=150,height_mm=125)
  model_path <- file.path(context$module_output_dir,"01_ROC分析对象.rds");saveRDS(roc_objects,model_path)
  tables <- list(
    write_result_table(context,"diagnostic-accuracy","01_ROC与AUC","ROC 与 AUC",auc_table),
    write_result_table(context,"diagnostic-accuracy","02_诊断阈值性能","诊断阈值性能",threshold_table,c("数据驱动 Youden 阈值为建模样本内估计，不能替代外部验证。")),
    write_result_table(context,"diagnostic-accuracy","03_AUC成对比较","AUC 成对比较",comparison_table)
  )
  if(any(threshold_table$threshold_source=="Youden（数据驱动）")) warnings<-c(warnings,"至少一个阈值由同一数据集按 Youden 指数选择；性能可能乐观。")
  if(subset$n_excluded_missing>0L)warnings<-c(warnings,paste0("因结局或标志物缺失排除 ",subset$n_excluded_missing," 行。"))
  new_module_result(
    "diagnostic-accuracy","roc-diagnostic-accuracy",started_at,tables=tables,
    figures=list(new_figure_object(figure_id="diagnostic_roc",title="ROC 曲线比较",exports=exports,source_data_path=source_path,conclusion="曲线展示标志物在当前样本中的区分度，不代表外部验证或临床净获益。",evidence_role="diagnostic_performance",statistics=list(n_definition=paste0(nrow(data)," 例；阳性 ",positive_n,"，阴性 ",negative_n),biological_replicates=paste0(nrow(data)," 个独立分析单位"),technical_replicates="不适用",center_statistic="ROC 曲线与 AUC",interval=paste0(confidence_level*100,"% AUC 置信区间"),test="DeLong AUC 比较（如适用）",multiple_comparison_correction=as.character(config$data_handling$multiple_testing$method %||% "holm")),source_module="diagnostic-accuracy")),
    model_objects=list(list(object_id="roc_objects",path=relative_path(model_path,context$run_dir),source_module="diagnostic-accuracy")),
    diagnostics=list(list(diagnostic="阳性/阴性最小样本数",value=min(positive_n,negative_n),rule="少于10拒绝执行",status="pass")),warnings=unique(warnings),
    limitations=c("PPV 和 NPV 依赖研究样本患病率。","同一样本选择阈值并评估性能会产生乐观偏倚。","ROC 不评价临床净获益。"),
    narrative=c(paste0("评估 ",length(markers)," 个诊断标志物在当前样本中的区分度。")),sample=list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,positive=positive_n,negative=negative_n),random_seed=context$random_seed
  )
}
