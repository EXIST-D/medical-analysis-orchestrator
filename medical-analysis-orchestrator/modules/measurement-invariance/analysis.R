run_module <- function(config, context) {
  started_at<-utc_now();parameters<-module_parameters(config,"measurement-invariance")
  items<-unique(as.character(parameters$items %||% character()));group_variable<-as.character(parameters$group %||% "");model_syntax<-as.character(parameters$model %||% "")
  ordered_items<-unique(as.character(parameters$ordered %||% character()));estimator<-as.character(parameters$estimator %||% if(length(ordered_items))"WLSMV" else "MLR");missing_method<-as.character(parameters$missing %||% if(length(ordered_items))"pairwise" else "fiml")
  requested_levels<-tolower(as.character(parameters$levels %||% c("configural","metric","scalar","strict")))
  if(length(items)<3L||!nzchar(group_variable)||!nzchar(model_syntax))stop("测量不变性必须指定至少三个条目、分组变量和明确 CFA 模型。",call.=FALSE)
  if(!all(requested_levels%in%c("configural","metric","scalar","strict")))stop("测量不变性层级不受支持。",call.=FALSE)
  assert_columns(context$data,c(items,group_variable),"measurement-invariance")
  data<-context$data[,c(items,group_variable),drop=FALSE];data[[group_variable]]<-droplevels(as.factor(data[[group_variable]]))
  group_counts<-table(data[[group_variable]]);if(length(group_counts)<2L)stop("测量不变性至少需要两个有效组。",call.=FALSE)
  if(any(group_counts<50L))stop("至少一个组少于 50 例，当前安全门不执行测量不变性。",call.=FALSE)
  if(length(ordered_items)){assert_columns(data,ordered_items,"measurement-invariance");for(item in ordered_items)data[[item]]<-ordered(data[[item]])}
  equality<-list(configural=character(),metric="loadings",scalar=if(length(ordered_items))c("loadings","thresholds") else c("loadings","intercepts"),strict=if(length(ordered_items))c("loadings","thresholds","residuals") else c("loadings","intercepts","residuals"))
  fits<-list();fit_rows<-list();warnings<-character()
  for(level in requested_levels){
    fit<-lavaan::cfa(model_syntax,data=data,group=group_variable,group.equal=equality[[level]],estimator=estimator,ordered=ordered_items,missing=missing_method,std.lv=TRUE)
    fits[[level]]<-fit
    measures<-lavaan::fitMeasures(fit,c("chisq","df","pvalue","cfi","tli","rmsea","rmsea.ci.lower","rmsea.ci.upper","srmr","aic","bic"))
    fit_rows[[length(fit_rows)+1L]]<-data.frame(level=level,converged=lavaan::lavInspect(fit,"converged"),chisq=measures["chisq"],df=measures["df"],p_value=measures["pvalue"],cfi=measures["cfi"],tli=measures["tli"],rmsea=measures["rmsea"],rmsea_conf_low=measures["rmsea.ci.lower"],rmsea_conf_high=measures["rmsea.ci.upper"],srmr=measures["srmr"],aic=measures["aic"],bic=measures["bic"],stringsAsFactors=FALSE)
  }
  fit_table<-do.call(rbind,fit_rows);comparison_rows<-list()
  if(nrow(fit_table)>=2L){for(i in 2:nrow(fit_table))comparison_rows[[length(comparison_rows)+1L]]<-data.frame(from=fit_table$level[i-1],to=fit_table$level[i],delta_cfi=fit_table$cfi[i]-fit_table$cfi[i-1],delta_rmsea=fit_table$rmsea[i]-fit_table$rmsea[i-1],delta_srmr=fit_table$srmr[i]-fit_table$srmr[i-1],decision=ifelse(abs(fit_table$cfi[i]-fit_table$cfi[i-1])<=.01&&abs(fit_table$rmsea[i]-fit_table$rmsea[i-1])<=.015,"未见明显恶化","需要审查不变性与部分不变性"),stringsAsFactors=FALSE)}
  comparison_table<-if(length(comparison_rows))do.call(rbind,comparison_rows)else data.frame(from=character(),to=character(),delta_cfi=double(),delta_rmsea=double(),delta_srmr=double(),decision=character())
  if(any(comparison_table$decision!="未见明显恶化"))warnings<-c(warnings,"至少一个不变性约束层级导致拟合明显恶化；不得继续比较潜变量均值而不审查部分不变性。")
  if(any(!fit_table$converged))warnings<-c(warnings,"至少一个测量不变性模型未收敛。")
  model_path<-file.path(context$module_output_dir,"01_测量不变性模型.rds");saveRDS(fits,model_path)
  tables<-list(write_result_table(context,"measurement-invariance","01_测量不变性拟合比较","测量不变性拟合比较",fit_table),write_result_table(context,"measurement-invariance","02_测量不变性差异","测量不变性层级差异",comparison_table,c("ΔCFI、ΔRMSEA 与 ΔSRMR 应结合理论、样本量和参数审查，不作为机械通过标准。")))
  diagnostics<-lapply(seq_len(nrow(fit_table)),function(i)list(diagnostic=paste0(fit_table$level[i]," 模型收敛"),value=as.numeric(fit_table$converged[i]),rule="1 表示收敛",status=ifelse(fit_table$converged[i],"pass","fail")))
  new_module_result("measurement-invariance","multi-group-measurement-invariance",started_at,tables=tables,model_objects=list(list(object_id="measurement_invariance_models",path=relative_path(model_path,context$run_dir),source_module="measurement-invariance")),diagnostics=diagnostics,warnings=unique(warnings),limitations=c("不变性判断不能仅依赖卡方差异检验或单一拟合阈值。","释放参数建立部分不变性必须有理论依据并完整记录。"),narrative=c(paste0("在 ",length(group_counts)," 个组中依次评估 ",paste(requested_levels,collapse="、")," 不变性。")),sample=list(n_input=nrow(data),groups=as.list(as.integer(group_counts)),group_labels=as.list(names(group_counts))),random_seed=context$random_seed)
}
