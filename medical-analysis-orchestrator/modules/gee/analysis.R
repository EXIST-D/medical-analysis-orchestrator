run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config,"gee")
  family_name <- tolower(as.character(parameters$family %||% "gaussian"))
  outcome <- as.character(parameters$outcome %||% "")
  event_level <- as.character(parameters$event_level %||% "")
  id_variable <- as.character(parameters$id %||% config$variables$id %||% "")
  time_variable <- as.character(parameters$time %||% config$variables$time %||% "")
  predictors <- unique(as.character(parameters$predictors %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  corstr <- tolower(as.character(parameters$correlation_structure %||% "exchangeable"))
  confidence_level <- as.numeric(parameters$confidence_level %||% .95)
  if(!family_name%in%c("gaussian","binomial","poisson"))stop("GEE family 仅支持 gaussian、binomial 或 poisson。",call.=FALSE)
  if(!corstr%in%c("independence","exchangeable","ar1","unstructured"))stop("GEE 相关结构不受支持。",call.=FALSE)
  if(!nzchar(outcome)||!nzchar(id_variable)||!length(predictors))stop("GEE 必须指定结局、聚类 ID 和预测变量。",call.=FALSE)
  variables<-unique(c(outcome,id_variable,time_variable,predictors));variables<-variables[nzchar(variables)]
  assert_columns(context$data,variables,"gee")
  subset<-analysis_subset(context$data,variables);data<-subset$data
  data$.analysis_order<-seq_len(nrow(data))
  if(nzchar(time_variable))data<-data[order(data[[id_variable]],safe_numeric(data[[time_variable]])),,drop=FALSE]
  data$.analysis_id<-data[[id_variable]]
  data$.analysis_wave<-if(nzchar(time_variable))safe_numeric(data[[time_variable]]) else ave(seq_len(nrow(data)),data$.analysis_id,FUN=seq_along)
  for(variable in intersect(categorical,predictors))data[[variable]]<-as.factor(data[[variable]])
  data<-apply_reference_levels(data,parameters$reference_levels %||% config$variables$reference_levels %||% list())
  if(family_name=="binomial"){
    observed<-unique(as.character(data[[outcome]]));if(length(observed)!=2L||!event_level%in%observed)stop("二项 GEE 必须指定存在的事件水平，且结局恰有两个水平。",call.=FALSE)
    data$.analysis_outcome<-as.integer(as.character(data[[outcome]])==event_level)
  }else{
    data$.analysis_outcome<-safe_numeric(data[[outcome]])
    if(any(!is.finite(data$.analysis_outcome)))stop("GEE 结局必须可转换为数值。",call.=FALSE)
    if(family_name=="poisson"&&(any(data$.analysis_outcome<0)||any(abs(data$.analysis_outcome-round(data$.analysis_outcome))>1e-8)))stop("Poisson GEE 结局必须为非负整数。",call.=FALSE)
  }
  cluster_sizes<-table(data[[id_variable]]);clusters<-length(cluster_sizes)
  if(clusters<10L)stop("GEE 聚类数量少于 10，稳健方差估计不可靠。",call.=FALSE)
  if(corstr=="ar1"&&!nzchar(time_variable))stop("AR-1 GEE 必须指定时间变量。",call.=FALSE)
  formula<-build_formula(".analysis_outcome",predictors)
  family_object<-switch(family_name,gaussian=stats::gaussian(),binomial=stats::binomial(),poisson=stats::poisson())
  model<-geepack::geeglm(formula,id=.analysis_id,waves=.analysis_wave,data=data,family=family_object,corstr=corstr,std.err="san.se")
  coef_matrix<-summary(model)$coefficients
  critical<-stats::qnorm((1+confidence_level)/2)
  coefficients<-data.frame(term=rownames(coef_matrix),estimate=coef_matrix[,"Estimate"],robust_std_error=coef_matrix[,"Std.err"],wald=coef_matrix[,"Wald"],p_value=coef_matrix[,"Pr(>|W|)"],effect_measure=if(family_name=="gaussian")"mean_difference" else if(family_name=="binomial")"odds_ratio" else "incidence_rate_ratio",effect=if(family_name=="gaussian")coef_matrix[,"Estimate"] else exp(coef_matrix[,"Estimate"]),conf_low=if(family_name=="gaussian")coef_matrix[,"Estimate"]-critical*coef_matrix[,"Std.err"] else exp(coef_matrix[,"Estimate"]-critical*coef_matrix[,"Std.err"]),conf_high=if(family_name=="gaussian")coef_matrix[,"Estimate"]+critical*coef_matrix[,"Std.err"] else exp(coef_matrix[,"Estimate"]+critical*coef_matrix[,"Std.err"]),stringsAsFactors=FALSE,row.names=NULL)
  qic<-tryCatch(geepack::QIC(model),error=function(e)c(QIC=NA_real_,QICu=NA_real_))
  alpha<-as.numeric(model$geese$alpha %||% NA_real_)
  model_summary<-data.frame(family=family_name,correlation_structure=corstr,n=nrow(data),clusters=clusters,min_cluster_size=min(cluster_sizes),max_cluster_size=max(cluster_sizes),working_correlation=alpha,qic=as.numeric(qic["QIC"]),qicu=as.numeric(qic["QICu"]),stringsAsFactors=FALSE)
  pearson<-stats::residuals(model,type="pearson");fitted<-stats::fitted(model)
  dispersion<-sum(pearson^2,na.rm=TRUE)/max(1,model$df.residual)
  diagnostics_table<-data.frame(diagnostic=c("聚类数量","工作相关参数","Pearson离散比"),value=c(clusters,alpha,dispersion),rule=c("少于10拒绝；少于30警告","信息性指标","Poisson >1.5 提示过度离散"),status=c(ifelse(clusters<30,"warning","pass"),"informational",ifelse(family_name=="poisson"&&dispersion>1.5,"warning","pass")),stringsAsFactors=FALSE)
  warnings<-character();if(clusters<30)warnings<-c(warnings,"聚类数量少于 30，稳健标准误的小样本表现需谨慎。")
  if(family_name=="poisson"&&dispersion>1.5)warnings<-c(warnings,"Poisson GEE 存在过度离散迹象。")
  if(subset$n_excluded_missing>0L)warnings<-c(warnings,paste0("因模型变量缺失排除 ",subset$n_excluded_missing," 行。"))
  figure_source<-data.frame(observation_index=seq_along(fitted),fitted_value=as.numeric(fitted),pearson_residual=as.numeric(pearson),cluster=as.character(data[[id_variable]]),stringsAsFactors=FALSE)
  source_path<-write_figure_source_data(context,"gee_diagnostics",figure_source)
  plot_diagnostics<-function(){palette<-medical_figure_palette();graphics::plot(fitted,pearson,xlab="拟合值",ylab="Pearson 残差",main="GEE 拟合诊断",col=palette[["accent"]],pch=16,cex=.55);graphics::abline(h=0,lty=2,col=palette[["neutral"]])}
  exports<-export_r_figure(config,context,"01_GEE拟合诊断图",plot_diagnostics,width_mm=145,height_mm=115)
  model_path<-file.path(context$module_output_dir,"01_GEE模型.rds");saveRDS(model,model_path)
  tables<-list(write_result_table(context,"gee","01_GEE系数","GEE 系数",coefficients),write_result_table(context,"gee","02_GEE模型摘要","GEE 模型摘要",model_summary),write_result_table(context,"gee","03_GEE诊断","GEE 诊断",diagnostics_table))
  new_module_result("gee",paste0(family_name,"-gee"),started_at,tables=tables,figures=list(new_figure_object(figure_id="gee_diagnostics",title="GEE 拟合诊断图",exports=exports,source_data_path=source_path,conclusion="诊断图审查群体平均模型残差；工作相关结构不等同于真实个体轨迹。",evidence_role="model_diagnostic",statistics=list(n_definition=paste0(nrow(data)," 次观测，",clusters," 个聚类"),biological_replicates=paste0(clusters," 个聚类单位"),technical_replicates="不适用",center_statistic="GEE 拟合值与 Pearson 残差",interval="不适用",test="稳健 Wald 检验",multiple_comparison_correction="未进行模型内多重校正"),source_module="gee")),model_objects=list(list(object_id="gee_model",path=relative_path(model_path,context$run_dir),source_module="gee")),diagnostics=lapply(seq_len(nrow(diagnostics_table)),function(i)as.list(diagnostics_table[i,])),warnings=unique(warnings),limitations=c("GEE 估计群体平均效应，不应解释为个体特异效应。","工作相关结构和失访机制必须由研究设计支持。"),narrative=c(paste0("使用 ",corstr," 工作相关结构拟合 ",family_name," GEE。")),sample=list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,clusters=clusters),random_seed=context$random_seed)
}
