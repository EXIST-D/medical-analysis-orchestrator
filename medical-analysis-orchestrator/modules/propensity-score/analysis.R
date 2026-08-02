weighted_mean_safe <- function(x,w)sum(w*x)/sum(w)
weighted_var_safe <- function(x,w){m<-weighted_mean_safe(x,w);sum(w*(x-m)^2)/sum(w)}

run_module <- function(config, context) {
  started_at<-utc_now();parameters<-module_parameters(config,"propensity-score")
  treatment<-as.character(parameters$treatment %||% "");treated_level<-as.character(parameters$treated_level %||% "");covariates<-unique(as.character(parameters$covariates %||% character()));categorical<-unique(as.character(parameters$categorical %||% character()));weight_type<-tolower(as.character(parameters$weight_type %||% "overlap"));estimand<-toupper(as.character(parameters$estimand %||% if(weight_type=="overlap")"ATO" else "ATE"));outcome<-as.character(parameters$outcome %||% "");outcome_type<-tolower(as.character(parameters$outcome_type %||% "continuous"));event_level<-as.character(parameters$event_level %||% "");confidence_level<-as.numeric(parameters$confidence_level %||% .95)
  if(!weight_type%in%c("iptw","overlap"))stop("倾向评分权重仅支持 iptw 或 overlap。",call.=FALSE)
  if(!nzchar(treatment)||!nzchar(treated_level)||!length(covariates))stop("倾向评分分析必须指定处理、处理水平和基线协变量。",call.=FALSE)
  variables<-unique(c(treatment,covariates,outcome));variables<-variables[nzchar(variables)];assert_columns(context$data,variables,"propensity-score")
  subset<-analysis_subset(context$data,variables);data<-subset$data
  observed<-unique(as.character(data[[treatment]]));if(length(observed)!=2L||!treated_level%in%observed)stop("当前倾向评分模块要求二分类处理且处理水平存在。",call.=FALSE)
  data$.treated<-as.integer(as.character(data[[treatment]])==treated_level)
  for(variable in intersect(categorical,covariates))data[[variable]]<-as.factor(data[[variable]])
  ps_formula<-build_formula(".treated",covariates);design<-stats::model.matrix(ps_formula,data=data)
  if(min(sum(data$.treated==1),sum(data$.treated==0))<20L)stop("任一处理组少于 20 例，当前安全门不执行倾向评分。",call.=FALSE)
  ps_model<-stats::glm(ps_formula,data=data,family=stats::binomial());ps<-pmin(pmax(stats::fitted(ps_model),1e-6),1-1e-6)
  if(weight_type=="overlap")weights<-ifelse(data$.treated==1,1-ps,ps) else {
    prevalence<-mean(data$.treated);weights<-if(estimand=="ATT")ifelse(data$.treated==1,1,ps/(1-ps)) else ifelse(data$.treated==1,prevalence/ps,(1-prevalence)/(1-ps))
  }
  if(any(!is.finite(weights))||any(weights<=0))stop("倾向评分权重不可用。",call.=FALSE)
  overlap_low<-max(min(ps[data$.treated==1]),min(ps[data$.treated==0]));overlap_high<-min(max(ps[data$.treated==1]),max(ps[data$.treated==0]));warnings<-character()
  if(overlap_low>=overlap_high)stop("处理组之间不存在倾向评分共同支持区间。",call.=FALSE)
  if(stats::quantile(weights,.99)>10)warnings<-c(warnings,"权重第99百分位超过10，存在极端权重；未自动截尾。")
  matrix<-design[,colnames(design)!="(Intercept)",drop=FALSE];balance_rows<-list()
  for(i in seq_len(ncol(matrix))){x<-matrix[,i];x1<-x[data$.treated==1];x0<-x[data$.treated==0];w1<-weights[data$.treated==1];w0<-weights[data$.treated==0];pooled_pre<-sqrt((stats::var(x1)+stats::var(x0))/2);pooled_post<-sqrt((weighted_var_safe(x1,w1)+weighted_var_safe(x0,w0))/2);balance_rows[[i]]<-data.frame(covariate=colnames(matrix)[i],smd_unweighted=ifelse(pooled_pre==0,0,(mean(x1)-mean(x0))/pooled_pre),smd_weighted=ifelse(pooled_post==0,0,(weighted_mean_safe(x1,w1)-weighted_mean_safe(x0,w0))/pooled_post),stringsAsFactors=FALSE)}
  balance<-do.call(rbind,balance_rows);max_smd<-max(abs(balance$smd_weighted),na.rm=TRUE);if(max_smd>.1)warnings<-c(warnings,"加权后至少一个协变量绝对标准化差异超过0.10。")
  weight_summary<-data.frame(group=c("未处理","处理"),n=c(sum(data$.treated==0),sum(data$.treated==1)),ps_mean=c(mean(ps[data$.treated==0]),mean(ps[data$.treated==1])),ps_min=c(min(ps[data$.treated==0]),min(ps[data$.treated==1])),ps_max=c(max(ps[data$.treated==0]),max(ps[data$.treated==1])),weight_mean=c(mean(weights[data$.treated==0]),mean(weights[data$.treated==1])),weight_max=c(max(weights[data$.treated==0]),max(weights[data$.treated==1])),effective_sample_size=c(sum(weights[data$.treated==0])^2/sum(weights[data$.treated==0]^2),sum(weights[data$.treated==1])^2/sum(weights[data$.treated==1]^2)),stringsAsFactors=FALSE)
  effect_table<-data.frame(outcome=character(),effect_measure=character(),estimate=double(),std_error=double(),conf_low=double(),conf_high=double(),p_value=double())
  outcome_model<-NULL
  if(nzchar(outcome)){
    if(outcome_type=="binary"){
      outcome_levels<-unique(as.character(data[[outcome]]));if(length(outcome_levels)!=2L||!event_level%in%outcome_levels)stop("二分类结局必须指定存在的事件水平。",call.=FALSE);data$.analysis_outcome<-as.integer(as.character(data[[outcome]])==event_level);measure<-"加权风险差"
    }else{data$.analysis_outcome<-safe_numeric(data[[outcome]]);if(any(!is.finite(data$.analysis_outcome)))stop("连续结局必须为数值。",call.=FALSE);measure<-"加权均值差"}
    data$.analysis_weight<-weights;survey_design<-survey::svydesign(ids=~1,weights=~.analysis_weight,data=data);outcome_model<-survey::svyglm(.analysis_outcome~.treated,design=survey_design,family=stats::gaussian())
    coef_matrix<-summary(outcome_model)$coefficients;estimate<-coef_matrix[".treated","Estimate"];se<-coef_matrix[".treated","Std. Error"];critical<-stats::qnorm((1+confidence_level)/2)
    effect_table<-data.frame(outcome=outcome,effect_measure=measure,estimate=estimate,std_error=se,conf_low=estimate-critical*se,conf_high=estimate+critical*se,p_value=coef_matrix[".treated","Pr(>|t|)"],stringsAsFactors=FALSE)
  }
  figure_source<-data.frame(propensity_score=ps,treatment=ifelse(data$.treated==1,"处理","未处理"),weight=weights,stringsAsFactors=FALSE);source_path<-write_figure_source_data(context,"propensity_overlap",figure_source)
  plot_overlap<-function(){graphics::hist(ps[data$.treated==0],breaks=20,freq=FALSE,col=grDevices::adjustcolor("grey30",.35),border=NA,xlim=c(0,1),xlab="倾向评分",main="倾向评分重叠");graphics::hist(ps[data$.treated==1],breaks=20,freq=FALSE,col=grDevices::adjustcolor("grey75",.55),border=NA,add=TRUE);graphics::legend("top",legend=c("未处理","处理"),fill=c(grDevices::adjustcolor("grey30",.35),grDevices::adjustcolor("grey75",.55)),bty="n")}
  exports<-export_r_figure(config,context,"01_倾向评分重叠图",plot_overlap,width_mm=150,height_mm=115)
  model_path<-file.path(context$module_output_dir,"01_倾向评分分析对象.rds");saveRDS(list(propensity_model=ps_model,outcome_model=outcome_model,weights=weights,estimand=estimand),model_path)
  tables<-list(write_result_table(context,"propensity-score","01_倾向评分与权重概况","倾向评分与权重概况",weight_summary),write_result_table(context,"propensity-score","02_协变量平衡","倾向评分加权前后协变量平衡",balance,c("绝对 SMD 0.10 仅作常用审计阈值，不替代临床判断。")),write_result_table(context,"propensity-score","03_加权效应估计","倾向评分加权效应估计",effect_table))
  diagnostics<-list(list(diagnostic="共同支持区间宽度",value=overlap_high-overlap_low,rule="<=0 拒绝执行",status="pass"),list(diagnostic="加权后最大绝对SMD",value=max_smd,rule=">0.10 提示残余不平衡",status=ifelse(max_smd>.1,"warning","pass")))
  new_module_result("propensity-score",paste0(weight_type,"-propensity-score"),started_at,tables=tables,figures=list(new_figure_object(figure_id="propensity_overlap",title="倾向评分重叠图",exports=exports,source_data_path=source_path,conclusion="展示处理组间共同支持；重叠本身不能证明无未测量混杂。",evidence_role="causal_design_diagnostic",statistics=list(n_definition=paste0(nrow(data)," 个完整案例"),biological_replicates=paste0(nrow(data)," 个独立分析单位"),technical_replicates="不适用",center_statistic="倾向评分分布",interval="不适用",test="协变量平衡使用标准化差异",multiple_comparison_correction="不适用"),source_module="propensity-score")),model_objects=list(list(object_id="propensity_score_analysis",path=relative_path(model_path,context$run_dir),source_module="propensity-score")),diagnostics=diagnostics,warnings=unique(warnings),limitations=c("仅能平衡已测量且正确建模的基线混杂变量。","因果解释要求明确 estimand、时间顺序、一致性、可交换性和 positivity。","本模块不自动截尾权重，也不按显著性选择协变量。"),narrative=c(paste0("使用 ",weight_type," 构造 ",estimand," 权重并审查协变量平衡。")),sample=list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,treated=sum(data$.treated),untreated=sum(1-data$.treated)),random_seed=context$random_seed)
}
