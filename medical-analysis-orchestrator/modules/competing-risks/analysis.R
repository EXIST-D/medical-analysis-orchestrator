run_module <- function(config, context) {
  started_at<-utc_now();parameters<-module_parameters(config,"competing-risks")
  time_variable<-as.character(parameters$time %||% "");status_variable<-as.character(parameters$status %||% "");event_code<-as.character(parameters$event_code %||% "");censor_code<-as.character(parameters$censor_code %||% "0");group_variable<-as.character(parameters$group %||% "");covariates<-unique(as.character(parameters$covariates %||% character()));categorical<-unique(as.character(parameters$categorical %||% character()));confidence_level<-as.numeric(parameters$confidence_level %||% .95)
  if(!nzchar(time_variable)||!nzchar(status_variable)||!nzchar(event_code))stop("竞争风险分析必须指定时间、状态和目标事件编码。",call.=FALSE)
  variables<-unique(c(time_variable,status_variable,group_variable,covariates));variables<-variables[nzchar(variables)];assert_columns(context$data,variables,"competing-risks")
  subset<-analysis_subset(context$data,variables);data<-subset$data;ftime<-safe_numeric(data[[time_variable]]);fstatus<-as.character(data[[status_variable]])
  if(any(!is.finite(ftime))||any(ftime<0))stop("竞争风险时间必须为非负数值。",call.=FALSE)
  if(!event_code%in%fstatus||!censor_code%in%fstatus)stop("目标事件或删失编码在有效数据中不存在。",call.=FALSE)
  noncensor<-setdiff(unique(fstatus),censor_code);if(length(noncensor)<2L)stop("竞争风险分析至少需要目标事件和一种竞争事件。",call.=FALSE)
  event_n<-sum(fstatus==event_code);if(event_n<10L)stop("目标事件少于 10，当前安全门不执行竞争风险模型。",call.=FALSE)
  status_factor<-factor(fstatus,levels=c(censor_code,setdiff(unique(fstatus),censor_code)));status_numeric<-as.integer(status_factor)-1L;target_numeric<-match(event_code,levels(status_factor))-1L
  group<-if(nzchar(group_variable))as.factor(data[[group_variable]]) else factor(rep("总体",nrow(data)))
  cif<-cmprsk::cuminc(ftime,status_numeric,group=group,cencode=0)
  curve_names<-setdiff(names(cif),"Tests");cif_rows<-list()
  for(name in curve_names){curve<-cif[[name]];cif_rows[[length(cif_rows)+1L]]<-data.frame(curve=name,time=curve$time,cumulative_incidence=curve$est,standard_error=sqrt(curve$var),conf_low=pmax(0,curve$est-stats::qnorm((1+confidence_level)/2)*sqrt(curve$var)),conf_high=pmin(1,curve$est+stats::qnorm((1+confidence_level)/2)*sqrt(curve$var)),stringsAsFactors=FALSE)}
  cif_table<-do.call(rbind,cif_rows)
  gray_table<-if(!is.null(cif$Tests)){raw<-as.data.frame(cif$Tests);data.frame(event=rownames(raw),statistic=raw$stat,df=raw$df,p_value=raw$pv,stringsAsFactors=FALSE,row.names=NULL)}else data.frame(event=character(),statistic=double(),df=double(),p_value=double())
  fg_model<-NULL;fg_table<-data.frame(term=character(),estimate=double(),subdistribution_hazard_ratio=double(),conf_low=double(),conf_high=double(),p_value=double())
  warnings<-character();diagnostics<-list(list(diagnostic="目标事件数",value=event_n,rule="少于10拒绝执行",status="pass"))
  if(length(covariates)){
    model_data<-data[,covariates,drop=FALSE];for(variable in intersect(categorical,covariates))model_data[[variable]]<-as.factor(model_data[[variable]])
    design<-stats::model.matrix(~.,data=model_data)[,-1,drop=FALSE]
    if(event_n/max(1,ncol(design))<5)stop("目标事件数相对于 Fine-Gray 参数数量不足。",call.=FALSE)
    fg_model<-cmprsk::crr(ftime,status_numeric,cov1=design,failcode=target_numeric,cencode=0)
    se<-sqrt(diag(fg_model$var));critical<-stats::qnorm((1+confidence_level)/2);est<-fg_model$coef
    fg_table<-data.frame(term=names(est),estimate=as.numeric(est),subdistribution_hazard_ratio=exp(est),conf_low=exp(est-critical*se),conf_high=exp(est+critical*se),p_value=2*stats::pnorm(abs(est/se),lower.tail=FALSE),stringsAsFactors=FALSE)
    converged<-isTRUE(fg_model$converged %||% TRUE);diagnostics<-c(diagnostics,list(list(diagnostic="Fine-Gray 模型收敛",value=as.numeric(converged),rule="1 表示收敛",status=ifelse(converged,"pass","fail"))))
    if(!converged)warnings<-c(warnings,"Fine-Gray 模型未收敛。")
  }
  if(subset$n_excluded_missing>0L)warnings<-c(warnings,paste0("因模型变量缺失排除 ",subset$n_excluded_missing," 行。"))
  source_path<-write_figure_source_data(context,"cumulative_incidence",cif_table)
  plot_cif<-function(){plot(cif,lty=seq_along(curve_names),col=seq_along(curve_names),xlab="随访时间",ylab="累积发生率",main="竞争风险累积发生函数")}
  exports<-export_r_figure(config,context,"01_累积发生函数图",plot_cif,width_mm=160,height_mm=120)
  model_path<-file.path(context$module_output_dir,"01_竞争风险模型.rds");saveRDS(list(cuminc=cif,fine_gray=fg_model,status_mapping=data.frame(original=levels(status_factor),numeric=seq_along(levels(status_factor))-1L)),model_path)
  tables<-list(write_result_table(context,"competing-risks","01_累积发生函数","累积发生函数",cif_table),write_result_table(context,"competing-risks","02_Gray检验","Gray 检验",gray_table),write_result_table(context,"competing-risks","03_Fine-Gray回归","Fine-Gray 回归",fg_table))
  new_module_result("competing-risks","cumulative-incidence-and-fine-gray",started_at,tables=tables,figures=list(new_figure_object(figure_id="cumulative_incidence",title="竞争风险累积发生函数",exports=exports,source_data_path=source_path,conclusion="展示目标事件与竞争事件共同存在时的累积发生率；亚分布风险比不等同于原因别风险比。",evidence_role="primary_estimate",statistics=list(n_definition=paste0(nrow(data)," 例；目标事件 ",event_n),biological_replicates=paste0(nrow(data)," 个独立分析单位"),technical_replicates="不适用",center_statistic="累积发生函数",interval=paste0(confidence_level*100,"% Wald 区间"),test="Gray 检验与 Fine-Gray 回归",multiple_comparison_correction="未进行多重校正"),source_module="competing-risks")),model_objects=list(list(object_id="competing_risk_models",path=relative_path(model_path,context$run_dir),source_module="competing-risks")),diagnostics=diagnostics,warnings=unique(warnings),limitations=c("目标事件、竞争事件和删失必须由研究方案预先定义。","亚分布风险比服务于累积发生率问题，不能与原因别 HR 混用。"),narrative=c(paste0("对目标事件编码 ",event_code," 执行竞争风险分析。")),sample=list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,target_events=event_n),random_seed=context$random_seed)
}
