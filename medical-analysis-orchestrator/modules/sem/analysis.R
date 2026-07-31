run_module <- function(config, context) {
  started_at<-utc_now();parameters<-module_parameters(config,"sem")
  model_syntax<-as.character(parameters$model %||% "");estimator<-as.character(parameters$estimator %||% "MLR");ordered_items<-unique(as.character(parameters$ordered %||% character()));missing_method<-as.character(parameters$missing %||% if(length(ordered_items))"pairwise" else "fiml");std_lv<-isTRUE(parameters$std_lv %||% TRUE);bootstrap_iterations<-as.integer(parameters$bootstrap_iterations %||% 0L)
  if(!nzchar(model_syntax))stop("SEM 必须提供明确的 lavaan 模型语法。",call.=FALSE)
  if(bootstrap_iterations<0L||bootstrap_iterations>5000L)stop("SEM Bootstrap 次数必须在 0 到 5000 之间。",call.=FALSE)
  data<-context$data
  if(length(ordered_items)){assert_columns(data,ordered_items,"sem");for(item in ordered_items)data[[item]]<-ordered(data[[item]])}
  se_type<-if(bootstrap_iterations>0L)"bootstrap" else "standard"
  fit<-lavaan::sem(model_syntax,data=data,estimator=estimator,ordered=ordered_items,missing=missing_method,std.lv=std_lv,se=se_type,bootstrap=if(bootstrap_iterations>0L)bootstrap_iterations else 1000L)
  converged<-lavaan::lavInspect(fit,"converged");if(!converged)stop("SEM 未收敛，停止生成正式结果。",call.=FALSE)
  measures<-lavaan::fitMeasures(fit,c("chisq","df","pvalue","cfi","tli","rmsea","rmsea.ci.lower","rmsea.ci.upper","srmr","aic","bic"))
  fit_table<-data.frame(chisq=measures["chisq"],df=measures["df"],p_value=measures["pvalue"],cfi=measures["cfi"],tli=measures["tli"],rmsea=measures["rmsea"],rmsea_conf_low=measures["rmsea.ci.lower"],rmsea_conf_high=measures["rmsea.ci.upper"],srmr=measures["srmr"],aic=measures["aic"],bic=measures["bic"],estimator=estimator,stringsAsFactors=FALSE)
  parameters_table<-lavaan::parameterEstimates(fit,standardized=TRUE,ci=TRUE,level=.95,boot.ci.type=if(bootstrap_iterations>0L)"perc" else "norm")
  parameters_table<-parameters_table[,intersect(c("lhs","op","rhs","label","est","se","z","pvalue","ci.lower","ci.upper","std.all"),names(parameters_table)),drop=FALSE]
  r2<-lavaan::inspect(fit,"r2");r2_table<-if(length(r2))data.frame(variable=names(r2),r_squared=as.numeric(r2),stringsAsFactors=FALSE)else data.frame(variable=character(),r_squared=double())
  warnings<-character();if(measures["cfi"]<.90||measures["rmsea"]>.08||measures["srmr"]>.08)warnings<-c(warnings,"至少一个常用整体拟合指标提示模型与数据拟合有限；阈值仅作审计，不可机械判定理论正确性。")
  improper<-any(parameters_table$op=="~~"&parameters_table$lhs==parameters_table$rhs&parameters_table$est<0,na.rm=TRUE);if(improper)warnings<-c(warnings,"检测到负方差等不当解。")
  model_path<-file.path(context$module_output_dir,"01_SEM模型.rds");saveRDS(fit,model_path)
  tables<-list(write_result_table(context,"sem","01_SEM拟合指标","结构方程模型拟合指标",fit_table),write_result_table(context,"sem","02_SEM参数估计","结构方程模型参数估计",parameters_table),write_result_table(context,"sem","03_SEM解释方差","结构方程模型解释方差",r2_table))
  diagnostics<-list(list(diagnostic="模型收敛",value=as.numeric(converged),rule="1 表示收敛",status="pass"),list(diagnostic="不当解",value=as.numeric(improper),rule="1 表示存在负方差等不当解",status=ifelse(improper,"fail","pass")))
  new_module_result("sem","structural-equation-model",started_at,tables=tables,model_objects=list(list(object_id="sem_model",path=relative_path(model_path,context$run_dir),source_module="sem")),diagnostics=diagnostics,warnings=unique(warnings),limitations=c("SEM 拟合良好不能证明模型唯一、理论正确或因果方向成立。","间接效应和路径方向必须由时间顺序与研究设计支持。","模型修改必须有理论依据并记录，不能按修改指数反复试配后宣称验证。"),narrative=c(paste0("使用 ",estimator," 估计已确认的结构方程模型。")),sample=list(n_input=nrow(data),n_used=lavaan::lavInspect(fit,"nobs"),bootstrap_iterations=bootstrap_iterations),random_seed=context$random_seed)
}
