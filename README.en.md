# Medical Analysis Orchestrator Skill

English | [简体中文](README.md)

`medical-analysis-orchestrator` is a general-purpose medical data analysis orchestration Skill for Codex and compatible agents. It is not a fixed statistical script. It turns user-provided clinical, medical, or questionnaire data into an inspectable, confirmation-gated, reproducible, and auditable workflow:

```text
inspect → recommend → confirm → execute → report
```

The Skill first inspects files, datasets, variable types, missingness, duplicates, and possible research roles in read-only mode. It then recommends suitable statistical methods from the research question, study design, and observed data structure. R analyses run only after the user explicitly confirms outcomes, variable roles, cleaning rules, reference levels, and model choices.

Current version: `0.0.6`

Release status: Beta / technical preview

## Why Use This Skill

- **Not a fixed pipeline:** network analysis, Bayesian networks, and other complex methods are optional modules rather than mandatory steps.
- **Data-informed method selection:** users who do not know which analysis to use receive a data profile, candidate roles, suitable methods, assumptions, and limitations first.
- **Confirmation-gated decisions:** the Skill does not silently choose primary outcomes, event levels, groups, reference categories, scale scoring, or case exclusions.
- **R-first modular design:** each method registers its own parameters and dependencies, making future statistical extensions incremental.
- **Traceable results:** runs record input hashes, plan fingerprints, R and package versions, random seeds, model objects, artifacts, and a manifest.
- **Engineered deliverables:** outputs include clearly numbered CSV files, three-line XLSX tables, R figures, Source Data, diagnostics, and Chinese Word reports.
- **Controlled manuscript support:** manuscript claims must be user-confirmed and linked to a table or figure from the same run.

## Default Academic Figure Template

`medical-academic-v1` is the default for every production figure: R-only rendering, white background, an available CJK-compatible font, no panel grid, and a restrained blue/orange/gray palette. Version 0.0.6 adds figure planning, semantic guardrails, actual DPI/pixel checks, and grayscale review copies. Every exported figure records Source Data, statistical metadata, the template identifier, and an interpretation boundary. Modules without a default figure still emit complete result tables and do not create decorative plots automatically.

![medical-academic-v1 contact sheet](medical-analysis-orchestrator/assets/figure-template/medical-academic-v1-contact-sheet.png)

## Repository Layout

```text
medical-analysis-orchestrator/
├── README.md
├── README.en.md
├── LICENSE
├── VERSION
└── medical-analysis-orchestrator/
    ├── SKILL.md
    ├── LICENSE.txt
    ├── agents/
    │   └── openai.yaml
    ├── modules/
    ├── references/
    ├── scripts/
    └── templates/
```

Repository-level documentation is kept separate from the installable Skill in `medical-analysis-orchestrator/`.

## Workflow

1. **`inspect`** — read-only inventory, variable dictionary, quality report, and cleaning candidates.
2. **`recommend`** — method recommendations with assumptions, required variables, diagnostics, alternatives, and unsupported interpretations.
3. **`confirm`** — explicit confirmation of outcomes, events, groups, references, covariates, cleaning actions, module parameters, and random seed.
4. **`execute`** — prepared analysis copy, automatic R discovery, project-level dependency resolution, and execution of confirmed modules.
5. **`report`** — validation of unified results, hashes, and module order before generating tables, figures, Source Data, model objects, logs, and Word reports.

No R packages are installed and no inferential models are run before confirmation.

## Ready Modules in 0.0.6

| Module | Current capability | Default figure | Status |
|---|---|---|---|
| `descriptive` | Continuous and categorical descriptive statistics | None | `ready` |
| `group-comparison` | Welch t/ANOVA, paired t, Wilcoxon/Kruskal–Wallis, paired Wilcoxon, chi-square/Fisher, and confirmed post-hoc comparisons | None | `ready` |
| `correlation` | Pearson, Spearman, Kendall, multiplicity correction, and effective-N matrix | None | `ready` |
| `linear-regression` | Multiple linear regression, HC3 robust standard errors, collinearity, and residual diagnostics | Linear-regression diagnostics | `ready` |
| `logistic-regression` | Binary logistic regression, OR, AUC, Brier score, apparent calibration, ROC, and safe separation handling | ROC curve | `ready` |
| `reliability-validity` | Alpha, omega, item analysis, KMO, Bartlett, criterion associations, and polychoric support for ordinal items | None | `ready` |
| `factor-analysis` | EFA, parallel analysis, CFA, CR, AVE, discriminant validity, and independent-sample split validation | Scree and parallel-analysis plot | `ready` |
| `mixed-effects` | Continuous-outcome LMM and binary-outcome GLMM | Mixed-model diagnostics | `ready` |
| `missing-data` | Missingness audit and MICE multiple-imputation object | Missingness proportions | `ready` |
| `generalized-regression` | Ordinal logistic, multinomial logistic, Poisson, and negative-binomial regression | None | `ready` |
| `survival` | Kaplan–Meier, log-rank, Cox regression, and proportional-hazards diagnostics | Kaplan–Meier curve | `ready` |
| `diagnostic-accuracy` | ROC, AUC, thresholds, sensitivity, specificity, and likelihood ratios | ROC comparison | `ready` |
| `gee` | Gaussian, binomial, and Poisson GEE | GEE diagnostics | `ready` |
| `measurement-invariance` | Configural, metric, scalar, and strict measurement invariance | None | `ready` |
| `competing-risks` | Cumulative incidence, Gray test, and Fine–Gray regression | Cumulative-incidence curves | `ready` |
| `propensity-score` | IPTW, overlap weighting, balance diagnostics, and weighted effects | Propensity-score overlap | `ready` |
| `sem` | Structural equation models, fit indices, standardized parameters, and indirect effects | None | `ready` |
| `network` | EBICglasso networks, centrality, bridge strength, and bootstrap assessment | Regularized network | `ready` |
| `bayesian` | Bayesian-network structure learning, edge stability, and whitelist/blacklist constraints | Averaged Bayesian network | `ready` |

## Requirements

- Windows 10/11 is the primary validated platform.
- R `>= 4.3.0`.
- Python 3.11 or a compatible version.
- Core Python orchestration packages: `pandas`, `openpyxl`, `PyYAML`, and `python-docx`; `xlrd`, `pyreadstat`, and `pyarrow` are installed only when the input format requires them.
- R packages are resolved and installed only for confirmed modules.

R dependencies are installed into the Skill-level `.r-library` by default, without modifying the system R library. `.r-library` is a local runtime artifact and is excluded from source distributions by both a release whitelist and `.gitignore`.

## Install

Use Codex Skill Installer with the GitHub directory URL:

```text
$skill-installer install https://github.com/EXIST-D/medical-analysis-orchestrator/tree/main/medical-analysis-orchestrator
```

Alternatively, clone the repository and copy the `medical-analysis-orchestrator/` subdirectory into the Skills directory used by Codex or another compatible agent. The installable entry point is:

```text
medical-analysis-orchestrator/SKILL.md
```

Restart Codex or reload Skills if the Skill does not appear immediately.

## Usage Examples

Inspect data without running models:

```text
Use $medical-analysis-orchestrator to inspect the medical data under "<data path>".
Return the file inventory, variable dictionary, quality issues, and possible analyses.
Do not run inferential models.
```

Request a recommendation:

```text
Use $medical-analysis-orchestrator to inspect "<data file>".
The research question is "<research question>".
Identify possible outcomes, groups, time variables, and scale items.
Recommend suitable medical statistics, assumptions, limitations, and decisions requiring confirmation,
then stop and wait for confirmation.
```

Run a confirmed analysis:

```text
Use $medical-analysis-orchestrator to analyze "<data file>".
The primary outcome is "<outcome>", predictors are "<variables>", and reference levels are "<references>".
Run descriptive statistics, univariable analysis, and logistic regression.
Record missing-data handling, diagnostics, R and package versions, and the random seed.
Generate three-line XLSX tables, R figures, and a Chinese Word report.
```

## Outputs

Typical formal outputs include:

```text
analysis_plan.yml
data_profile.csv
01_数据整理/
02_描述性统计/
03_单因素分析/
04_相关性分析/
05_多元线性回归/
06_Logistic回归/
07_信度与效度分析/
08_探索性与验证性因子分析/
09_混合效应模型/
10_缺失数据与多重插补/
20_广义回归/
21_基础生存分析/
22_诊断试验准确性/
23_广义估计方程/
24_测量不变性/
25_竞争风险/
26_倾向评分/
27_结构方程模型/
30_网络分析/
31_贝叶斯网络/
90_最终报告/
99_运行记录/
sessionInfo.txt
package_versions.csv
manifest.json
```

Tables are emitted as machine-readable CSV and minimally styled three-line XLSX workbooks. Statistical figures are generated by R and registered with Source Data and statistical metadata.

## Safety, Privacy, and Statistical Boundaries

- Raw data remain read-only.
- Real data are never changed to obtain significance, an expected direction, or a desired network.
- Outliers, duplicates, cases, missing values, and scale scoring are not silently changed.
- Primary outcomes, event levels, groups, reference categories, and multiplicity strategies require confirmation.
- Complex models warn or stop under inadequate samples, rare events, severe missingness, complete separation, non-convergence, or failed assumptions.
- Cross-sectional associations, network edges, and Bayesian-network directions are not described as established causal effects.
- Reports consume only validated objects from the same `run_id`.
- Row-level patient data are excluded from logs, manifests, and reports by default.

This project is not a de-identification or anonymization tool. Users remain responsible for ethics approval, consent, privacy, institutional governance, and applicable law.

This software does not provide medical advice, diagnosis, or treatment recommendations and does not replace clinical researchers, medical statisticians, data-security professionals, or ethics review.

## Validation Status

Before the `0.0.6` release, the project completed:

- 32 local end-to-end qualification tests and 3 repository release smoke tests;
- Skill structure validation;
- Python, R, and YAML syntax checks;
- local documentation-link checks;
- real R module execution;
- three-line XLSX, statistical figure, Source Data, and Word report validation;
- release scans excluding `.r-library`, caches, runtime artifacts, and sensitive information.

The main validated environment is Windows with R 4.6.1 and Python 3.11. GitHub Actions provides a Windows + R 4.3/4.4/4.6 contract/R-parse matrix and a LibreOffice Word/XLSX page-rendering smoke test. External validation, real study designs, and cross-version visual baselines still require study-specific review.

## Originality and Third-Party Dependencies

This project is independently designed and maintained. Its workflow, confirmation gate, module registry, configuration contracts, unified result object, figure evidence contract, output validation, and reporting orchestration are implemented within this project.

The project may learn from public statistical standards, software documentation, and sound engineering practices, but it does not package third-party Skills, proprietary code, real patient data, or restricted materials. R, Python, and statistical packages retain their respective licenses. This repository's MIT License covers only the original code and documentation distributed here.

## Author and Maintenance

Created and maintained by [EXIST-D](https://github.com/EXIST-D).

Bug reports, compatibility feedback, statistical-method suggestions, and feature requests are welcome through [GitHub Issues](https://github.com/EXIST-D/medical-analysis-orchestrator/issues). Pull requests are welcome. By submitting a contribution, you confirm that you have the right to provide it and agree that it may be distributed under this repository's MIT License.

Suggested citation:

```text
EXIST-D. medical-analysis-orchestrator (Version 0.0.5) [Computer software].
GitHub. https://github.com/EXIST-D/medical-analysis-orchestrator
```

## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE). The packaged Skill includes a copy at `medical-analysis-orchestrator/LICENSE.txt`.

The software is provided “as is,” without warranty of any kind. The full license text controls.
