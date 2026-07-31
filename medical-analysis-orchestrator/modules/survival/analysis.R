run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "survival")
  time_variable <- as.character(parameters$time %||% config$variables$time %||% "")
  event_variable <- as.character(parameters$event %||% config$variables$event %||% "")
  event_level <- as.character(parameters$event_level %||% "")
  group_variable <- as.character(parameters$group %||% "")
  predictors <- unique(as.character(parameters$predictors %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  confidence_level <- as.numeric(parameters$confidence_level %||% .95)
  if (!nzchar(time_variable) || !nzchar(event_variable) || !nzchar(event_level)) {
    stop("生存分析必须指定时间、事件变量和事件水平。", call. = FALSE)
  }
  variables <- unique(c(time_variable, event_variable, group_variable, predictors))
  variables <- variables[nzchar(variables)]
  assert_columns(context$data, variables, "survival")
  subset <- analysis_subset(context$data, variables)
  data <- subset$data
  data$.analysis_time <- safe_numeric(data[[time_variable]])
  if (any(!is.finite(data$.analysis_time)) || any(data$.analysis_time < 0)) stop("生存时间必须为非负数值。", call. = FALSE)
  data$.analysis_event <- as.integer(as.character(data[[event_variable]]) == event_level)
  events <- sum(data$.analysis_event)
  if (events < 5L) stop("事件数少于 5，不能稳定执行基础生存分析。", call. = FALSE)
  for (variable in intersect(categorical, c(group_variable, predictors))) data[[variable]] <- as.factor(data[[variable]])
  data <- apply_reference_levels(data, parameters$reference_levels %||% config$variables$reference_levels %||% list())
  survival_object <- survival::Surv(data$.analysis_time, data$.analysis_event)
  km_formula <- if (nzchar(group_variable)) stats::as.formula(paste("survival_object ~", quote_name(group_variable))) else survival_object ~ 1
  km_model <- survival::survfit(km_formula, data = data, conf.int = confidence_level)
  km_summary <- summary(km_model)
  strata <- if (is.null(km_summary$strata)) rep("总体", length(km_summary$time)) else as.character(km_summary$strata)
  km_table <- data.frame(
    stratum = strata, time = km_summary$time, n_risk = km_summary$n.risk,
    n_event = km_summary$n.event, survival = km_summary$surv,
    conf_low = km_summary$lower, conf_high = km_summary$upper,
    stringsAsFactors = FALSE
  )
  logrank <- NULL
  if (nzchar(group_variable)) logrank <- survival::survdiff(km_formula, data = data)
  cox_model <- NULL
  cox_table <- data.frame(term=character(),estimate=double(),std_error=double(),hazard_ratio=double(),conf_low=double(),conf_high=double(),p_value=double())
  ph_table <- data.frame(term=character(),chisq=double(),df=double(),p_value=double(),status=character())
  diagnostics <- list()
  warnings <- character()
  if (length(predictors)) {
    design <- stats::model.matrix(build_formula(time_variable, predictors), data=data)
    parameters_n <- ncol(design) - 1L
    if (events / max(1L, parameters_n) < 5) stop("事件数相对于 Cox 模型参数数量不足。", call. = FALSE)
    cox_formula <- stats::as.formula(paste0("survival::Surv(.analysis_time, .analysis_event) ~ ", paste(vapply(predictors, quote_name, character(1)), collapse=" + ")))
    cox_model <- survival::coxph(cox_formula, data=data, x=TRUE, y=TRUE, model=TRUE)
    summary_cox <- summary(cox_model)
    critical <- stats::qnorm((1 + confidence_level) / 2)
    estimates <- summary_cox$coefficients
    cox_table <- data.frame(
      term=rownames(estimates), estimate=estimates[,"coef"], std_error=estimates[,"se(coef)"],
      hazard_ratio=exp(estimates[,"coef"]),
      conf_low=exp(estimates[,"coef"] - critical*estimates[,"se(coef)"]),
      conf_high=exp(estimates[,"coef"] + critical*estimates[,"se(coef)"]),
      p_value=estimates[,"Pr(>|z|)"], stringsAsFactors=FALSE,row.names=NULL
    )
    ph <- survival::cox.zph(cox_model)
    ph_raw <- as.data.frame(ph$table)
    ph_table <- data.frame(
      term=rownames(ph_raw), chisq=ph_raw[,"chisq"], df=ph_raw[,"df"], p_value=ph_raw[,"p"],
      status=ifelse(ph_raw[,"p"] < .05,"warning","pass"), stringsAsFactors=FALSE,row.names=NULL
    )
    diagnostics <- lapply(seq_len(nrow(ph_table)), function(i) list(
      diagnostic=paste0("比例风险假设：",ph_table$term[i]), value=ph_table$p_value[i],
      rule="Schoenfeld 残差检验 P<0.05 提示比例风险假设可能不满足",status=ph_table$status[i]
    ))
    if (any(ph_table$status == "warning")) warnings <- c(warnings,"比例风险假设存在不满足迹象；应考虑分层或时间变化效应敏感性分析。")
  }
  if (subset$n_excluded_missing > 0L) warnings <- c(warnings,paste0("因生存分析变量缺失排除 ",subset$n_excluded_missing," 行。"))
  source_data_path <- write_figure_source_data(context,"kaplan_meier",km_table)
  plot_km <- function() {
    graphics::plot(km_model,xlab="随访时间",ylab="生存概率",main="Kaplan-Meier 生存曲线",lwd=2,col=seq_len(max(1,length(km_model$strata))),mark.time=TRUE)
    if (!is.null(km_model$strata)) graphics::legend("bottomleft",legend=names(km_model$strata),col=seq_along(km_model$strata),lwd=2,bty="n")
  }
  exports <- export_r_figure(config,context,"01_Kaplan-Meier生存曲线",plot_km,width_mm=160,height_mm=120)
  model_summary <- data.frame(
    n=nrow(data),events=events,censored=nrow(data)-events,
    groups=if(nzchar(group_variable))nlevels(droplevels(as.factor(data[[group_variable]]))) else 1L,
    logrank_chisq=if(is.null(logrank))NA_real_ else unname(logrank$chisq),
    logrank_df=if(is.null(logrank))NA_real_ else length(logrank$n)-1L,
    logrank_p=if(is.null(logrank))NA_real_ else stats::pchisq(logrank$chisq,length(logrank$n)-1L,lower.tail=FALSE),
    stringsAsFactors=FALSE
  )
  model_path <- file.path(context$module_output_dir,"01_生存分析模型.rds")
  saveRDS(list(km=km_model,cox=cox_model,logrank=logrank),model_path)
  tables <- list(
    write_result_table(context,"survival","01_Kaplan-Meier估计","Kaplan-Meier 生存估计",km_table),
    write_result_table(context,"survival","02_Cox回归","Cox 比例风险回归",cox_table),
    write_result_table(context,"survival","03_比例风险诊断","比例风险假设诊断",ph_table),
    write_result_table(context,"survival","04_生存分析摘要","生存分析摘要",model_summary)
  )
  new_module_result(
    "survival","kaplan-meier-and-cox",started_at,tables=tables,
    figures=list(new_figure_object(
      figure_id="kaplan_meier",title="Kaplan-Meier 生存曲线",exports=exports,source_data_path=source_data_path,
      conclusion="展示删失条件下的生存概率估计；曲线差异不自动构成因果效应。",evidence_role="primary_estimate",
      statistics=list(n_definition=paste0(nrow(data)," 名纳入对象，",events," 个事件"),biological_replicates=paste0(nrow(data)," 个独立分析单位"),technical_replicates="不适用",center_statistic="Kaplan-Meier 生存概率",interval=paste0(confidence_level*100,"% Greenwood 区间"),test=if(is.null(logrank))"未执行组间检验" else "log-rank 检验",multiple_comparison_correction="未进行多重比较"),source_module="survival"
    )),
    model_objects=list(list(object_id="survival_models",path=relative_path(model_path,context$run_dir),source_module="survival")),
    diagnostics=diagnostics,warnings=unique(warnings),
    limitations=c("须由研究方案确认时间起点、删失和事件定义。","Cox HR 依赖比例风险及函数形式假设。"),
    narrative=c(paste0("纳入 ",nrow(data)," 例，观察到 ",events," 个事件。")),
    sample=list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,events=events),random_seed=context$random_seed
  )
}
