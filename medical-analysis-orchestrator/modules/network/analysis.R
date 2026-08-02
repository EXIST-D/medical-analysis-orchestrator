network_edges <- function(matrix) {
  index<-which(upper.tri(matrix)&matrix!=0,arr.ind=TRUE)
  if(!nrow(index))return(data.frame(node_1=character(),node_2=character(),weight=double()))
  data.frame(node_1=rownames(matrix)[index[,1]],node_2=colnames(matrix)[index[,2]],weight=matrix[index],stringsAsFactors=FALSE)
}

run_module <- function(config, context) {
  started_at<-utc_now();parameters<-module_parameters(config,"network")
  nodes<-unique(as.character(parameters$nodes %||% character()));correlation<-tolower(as.character(parameters$correlation %||% "spearman"));tuning<-as.numeric(parameters$tuning %||% .5);bootstrap_iterations<-as.integer(parameters$bootstrap_iterations %||% 100L);communities<-parameters$communities %||% list()
  if(length(nodes)<3L)stop("网络分析至少需要三个节点。",call.=FALSE)
  if(!correlation%in%c("pearson","spearman"))stop("当前网络模块仅支持 Pearson 或 Spearman 相关。",call.=FALSE)
  if(!is.finite(tuning)||tuning<0||tuning>1)stop("EBIC tuning 必须在 0 到 1 之间。",call.=FALSE)
  if(bootstrap_iterations<20L||bootstrap_iterations>2000L)stop("网络 Bootstrap 次数必须在 20 到 2000 之间。",call.=FALSE)
  assert_columns(context$data,nodes,"network");subset<-analysis_subset(context$data,nodes);data<-as.data.frame(lapply(subset$data,safe_numeric),check.names=FALSE)
  if(any(!vapply(data,function(x)all(is.finite(x))&&stats::sd(x)>0,logical(1))))stop("所有网络节点必须为有变异的数值变量。",call.=FALSE)
  if(nrow(data)<max(50L,5L*length(nodes)))stop("有效样本量不足以支持当前节点数的网络估计。",call.=FALSE)
  correlation_matrix<-stats::cor(data,method=correlation);if(any(!is.finite(correlation_matrix)))stop("相关矩阵包含非有限值。",call.=FALSE)
  network<-qgraph::EBICglasso(correlation_matrix,n=nrow(data),gamma=tuning)
  dimnames(network)<-list(nodes,nodes);edges<-network_edges(network)
  strength<-rowSums(abs(network));centrality<-data.frame(node=nodes,strength=as.numeric(strength),bridge_strength=NA_real_,stringsAsFactors=FALSE)
  if(length(communities)){
    membership<-setNames(rep(NA_character_,length(nodes)),nodes)
    for(group in names(communities))membership[intersect(nodes,as.character(communities[[group]]))]<-group
    if(any(is.na(membership)))stop("communities 必须为每个网络节点指定且仅指定一个社区。",call.=FALSE)
    centrality$bridge_strength<-vapply(nodes,function(node){other<-nodes[membership[nodes]!=membership[node]];sum(abs(network[node,other]))},numeric(1))
  }
  set.seed(context$random_seed);boot_edges<-vector("list",bootstrap_iterations);failures<-0L
  for(i in seq_len(bootstrap_iterations)){
    sample_index<-sample.int(nrow(data),replace=TRUE);boot_cor<-stats::cor(data[sample_index,,drop=FALSE],method=correlation)
    boot_network<-tryCatch(qgraph::EBICglasso(boot_cor,n=nrow(data),gamma=tuning),error=function(e)NULL)
    if(is.null(boot_network)){failures<-failures+1L;next};dimnames(boot_network)<-list(nodes,nodes);frame<-network_edges(boot_network);if(nrow(frame)){frame$iteration<-i;boot_edges[[i]]<-frame}
  }
  successful<-bootstrap_iterations-failures;if(successful<ceiling(.8*bootstrap_iterations))stop("网络 Bootstrap 成功率低于 80%。",call.=FALSE)
  all_pairs<-utils::combn(nodes,2L,simplify=FALSE);stability_rows<-lapply(all_pairs,function(pair){values<-numeric(bootstrap_iterations);for(i in seq_len(bootstrap_iterations)){frame<-boot_edges[[i]];if(!is.null(frame)&&nrow(frame)){hit<-(frame$node_1==pair[1]&frame$node_2==pair[2])|(frame$node_1==pair[2]&frame$node_2==pair[1]);if(any(hit))values[i]<-frame$weight[which(hit)[1]]}};data.frame(node_1=pair[1],node_2=pair[2],selection_probability=mean(values!=0),mean_weight=mean(values),conf_low=stats::quantile(values,.025),conf_high=stats::quantile(values,.975),stringsAsFactors=FALSE)})
  stability<-do.call(rbind,stability_rows);warnings<-character();if(failures>0L)warnings<-c(warnings,paste0("Bootstrap 中 ",failures," 次网络估计失败。"));if(nrow(edges)==0L)warnings<-c(warnings,"正则化网络未保留任何边。")
  source_path<-write_figure_source_data(context,"network_edges",edges)
  plot_network<-function(){palette<-medical_figure_palette();qgraph::qgraph(network,layout="spring",labels=nodes,vsize=6,edge.labels=FALSE,color="white",border.color="black",posCol=palette[["accent"]],negCol=palette[["warning"]],label.color="black",title="正则化偏相关网络")}
  exports<-export_r_figure(config,context,"01_网络图",plot_network,width_mm=160,height_mm=140)
  model_path<-file.path(context$module_output_dir,"01_网络模型.rds");saveRDS(list(network=network,correlation=correlation_matrix,bootstrap=stability,communities=communities),model_path)
  tables<-list(write_result_table(context,"network","01_网络边","网络边",edges),write_result_table(context,"network","02_中心性","网络中心性",centrality),write_result_table(context,"network","03_Bootstrap边稳定性","Bootstrap 边稳定性",stability,c("边选择概率和区间仅反映重抽样稳定性，不是因果证据。")))
  diagnostics<-list(list(diagnostic="样本量/节点数",value=nrow(data)/length(nodes),rule="低于5拒绝执行",status="pass"),list(diagnostic="Bootstrap成功比例",value=successful/bootstrap_iterations,rule="低于0.80拒绝执行",status="pass"))
  new_module_result("network","regularized-partial-correlation-network",started_at,tables=tables,figures=list(new_figure_object(figure_id="network_edges",title="正则化偏相关网络",exports=exports,source_data_path=source_path,conclusion="网络边表示在所选估计条件下的条件关联；边和中心性不得解释为确定因果关系。",evidence_role="exploratory_association",statistics=list(n_definition=paste0(nrow(data)," 个完整案例，",length(nodes)," 个节点"),biological_replicates=paste0(nrow(data)," 个独立分析单位"),technical_replicates="不适用",center_statistic="EBICglasso 正则化偏相关",interval=paste0(bootstrap_iterations," 次非参数 Bootstrap 2.5%–97.5%分位区间"),test="未执行逐边显著性检验",multiple_comparison_correction="通过正则化控制稀疏性，不等同于 P 值校正"),source_module="network")),model_objects=list(list(object_id="network_model",path=relative_path(model_path,context$run_dir),source_module="network")),diagnostics=diagnostics,warnings=unique(warnings),limitations=c("横断面网络边和中心性不能确立因果方向。","节点定义、量表计分、相关类型和正则化参数必须预先确认。","当前版本不自动执行组间网络比较。"),narrative=c(paste0("对 ",length(nodes)," 个节点估计正则化偏相关网络并执行 ",bootstrap_iterations," 次 Bootstrap。")),sample=list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,nodes=length(nodes)),random_seed=context$random_seed)
}
