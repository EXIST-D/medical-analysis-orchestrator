as_arc_constraints <- function(value,label){
  if(is.null(value)||!length(value))return(NULL)
  if(is.data.frame(value))frame<-value else if(is.list(value)&&all(vapply(value,function(item)is.list(item)&&all(c("from","to")%in%names(item)),logical(1)))){
    frame<-do.call(rbind,lapply(value,function(item)data.frame(from=as.character(item$from),to=as.character(item$to),stringsAsFactors=FALSE)))
  }else stop(label," 必须是由 from/to 映射组成的列表。",call.=FALSE)
  if(!all(c("from","to")%in%names(frame)))stop(label," 必须由 from/to 两列构成。",call.=FALSE)
  frame<-frame[,c("from","to"),drop=FALSE];frame[]<-lapply(frame,as.character);frame
}

run_module <- function(config, context) {
  started_at<-utc_now();parameters<-module_parameters(config,"bayesian")
  nodes<-unique(as.character(parameters$nodes %||% character()));algorithm<-tolower(as.character(parameters$algorithm %||% "hc"));bootstrap_iterations<-as.integer(parameters$bootstrap_iterations %||% 100L);strength_threshold<-as.numeric(parameters$strength_threshold %||% .85);whitelist<-as_arc_constraints(parameters$whitelist %||% NULL,"whitelist");blacklist<-as_arc_constraints(parameters$blacklist %||% NULL,"blacklist")
  if(length(nodes)<3L)stop("贝叶斯网络至少需要三个节点。",call.=FALSE)
  if(!algorithm%in%c("hc","tabu"))stop("贝叶斯网络结构学习算法仅支持 hc 或 tabu。",call.=FALSE)
  if(bootstrap_iterations<20L||bootstrap_iterations>2000L)stop("贝叶斯网络 Bootstrap 次数必须在 20 到 2000 之间。",call.=FALSE)
  if(!is.finite(strength_threshold)||strength_threshold<=.5||strength_threshold>1)stop("平均网络边强度阈值必须在 0.5 到 1 之间。",call.=FALSE)
  for(constraints in list(whitelist,blacklist))if(!is.null(constraints)&&any(!constraints$from%in%nodes|!constraints$to%in%nodes|constraints$from==constraints$to))stop("贝叶斯网络约束端点必须是不同的已选节点。",call.=FALSE)
  assert_columns(context$data,nodes,"bayesian");subset<-analysis_subset(context$data,nodes);data<-subset$data
  for(variable in names(data))if(is.character(data[[variable]]))data[[variable]]<-as.factor(data[[variable]])
  all_numeric<-all(vapply(data,is.numeric,logical(1)));all_discrete<-all(vapply(data,function(x)is.factor(x)||is.ordered(x),logical(1)));score<-if(all_numeric)"bic-g" else if(all_discrete)"bic" else "bic-cg"
  if(nrow(data)<max(50L,5L*length(nodes)))stop("有效样本量不足以支持当前节点数的结构学习。",call.=FALSE)
  algorithm_args<-list(score=score);if(!is.null(whitelist))algorithm_args$whitelist<-whitelist;if(!is.null(blacklist))algorithm_args$blacklist<-blacklist
  learner<-getExportedValue("bnlearn",algorithm);network<-do.call(learner,c(list(x=data),algorithm_args))
  boot_strength<-bnlearn::boot.strength(data,R=bootstrap_iterations,algorithm=algorithm,algorithm.args=algorithm_args,cpdag=FALSE)
  averaged<-bnlearn::averaged.network(boot_strength,threshold=strength_threshold)
  averaged_arcs<-bnlearn::arcs(averaged);edge_table<-if(nrow(averaged_arcs))merge(as.data.frame(averaged_arcs,stringsAsFactors=FALSE),as.data.frame(boot_strength,stringsAsFactors=FALSE),by=c("from","to"),all.x=TRUE) else data.frame(from=character(),to=character(),strength=double(),direction=double())
  strength_table<-as.data.frame(boot_strength,stringsAsFactors=FALSE);strength_table<-strength_table[order(strength_table$strength,decreasing=TRUE),,drop=FALSE]
  warnings<-character();if(!nrow(edge_table))warnings<-c(warnings,"按确认阈值平均后未保留稳定边。")
  if(any(edge_table$direction<.6,na.rm=TRUE))warnings<-c(warnings,"至少一条保留边的方向稳定性较低；不得据此宣称方向性因果关系。")
  source_path<-write_figure_source_data(context,"bayesian_network_edges",edge_table)
  graph<-igraph::make_empty_graph(n=length(nodes),directed=TRUE);igraph::V(graph)$name<-nodes
  if(nrow(edge_table))graph<-igraph::add_edges(graph,as.vector(t(as.matrix(edge_table[,c("from","to")]))))
  plot_network<-function(){palette<-medical_figure_palette();set.seed(context$random_seed);igraph::plot.igraph(graph,layout=igraph::layout_with_fr(graph),vertex.color="white",vertex.frame.color="black",vertex.label.color="black",edge.color=palette[["accent"]],edge.arrow.size=.45,main="Bootstrap 平均贝叶斯网络")}
  exports<-export_r_figure(config,context,"01_贝叶斯网络图",plot_network,width_mm=160,height_mm=140)
  model_path<-file.path(context$module_output_dir,"01_贝叶斯网络模型.rds");saveRDS(list(initial=network,bootstrap_strength=boot_strength,averaged=averaged,score=score,constraints=list(whitelist=whitelist,blacklist=blacklist)),model_path)
  tables<-list(write_result_table(context,"bayesian","01_贝叶斯网络边","贝叶斯网络稳定边",edge_table),write_result_table(context,"bayesian","02_Bootstrap边强度","Bootstrap 边强度与方向",strength_table,c("strength 表示边出现比例；direction 为在该方向与反方向之间的条件方向比例。")))
  diagnostics<-list(list(diagnostic="样本量/节点数",value=nrow(data)/length(nodes),rule="低于5拒绝执行",status="pass"),list(diagnostic="稳定边数量",value=nrow(edge_table),rule="信息性指标",status="informational"))
  new_module_result("bayesian","bayesian-network-structure-learning",started_at,tables=tables,figures=list(new_figure_object(figure_id="bayesian_network_edges",title="Bootstrap 平均贝叶斯网络",exports=exports,source_data_path=source_path,conclusion="图中边表示在算法、评分和先验约束下较稳定的条件依赖结构；箭头不得自动解释为因果方向。",evidence_role="exploratory_conditional_dependence",statistics=list(n_definition=paste0(nrow(data)," 个完整案例，",length(nodes)," 个节点"),biological_replicates=paste0(nrow(data)," 个独立分析单位"),technical_replicates="不适用",center_statistic=paste0(algorithm," 结构学习与 ",score," 评分"),interval=paste0(bootstrap_iterations," 次 Bootstrap 边强度"),test="未执行逐边显著性检验",multiple_comparison_correction="不适用"),source_module="bayesian")),model_objects=list(list(object_id="bayesian_network",path=relative_path(model_path,context$run_dir),source_module="bayesian")),diagnostics=diagnostics,warnings=unique(warnings),limitations=c("观察数据结构学习通常不能单独识别因果方向。","结果依赖节点定义、数据类型、评分函数、搜索算法和黑白名单。","边稳定性不是因果效应量，也不是外部验证。"),narrative=c(paste0("使用 ",algorithm," 与 ",score," 学习结构，并执行 ",bootstrap_iterations," 次 Bootstrap。")),sample=list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,nodes=length(nodes)),random_seed=context$random_seed)
}
