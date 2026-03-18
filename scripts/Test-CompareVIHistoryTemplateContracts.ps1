Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manualTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-workflow-dispatch.yml'
$pullRequestTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-pull-request-diagnostics.yml'
$pullRequestAutoTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-pull-request-diagnostics-auto.yml'
$pullRequestPublishTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-pull-request-diagnostics-publish.yml'
$agentCanaryTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-agent-canary-evaluate.yml'
$commentTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-comment-gated.yml'
$manualExplorationTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-manual-vi-exploration.yml'
$safeTemplatesPath = Join-Path $repoRoot 'docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md'
$publishedValidationWorkflowPath = Join-Path $repoRoot '.github/workflows/published-consumer-validation.yml'
$pullRequestWorkflowPath = Join-Path $repoRoot '.github/workflows/pull-request-diagnostics.yml'
$pullRequestAutoWorkflowPath = Join-Path $repoRoot '.github/workflows/pull-request-diagnostics-auto.yml'
$pullRequestPublishWorkflowPath = Join-Path $repoRoot '.github/workflows/pull-request-diagnostics-publish.yml'
$agentCanaryWorkflowPath = Join-Path $repoRoot '.github/workflows/pull-request-diagnostics-canary-evaluate.yml'
$manualExplorationWorkflowPath = Join-Path $repoRoot '.github/workflows/manual-vi-exploration.yml'
$smokeWorkflowPath = Join-Path $repoRoot '.github/workflows/smoke.yml'
$releaseWorkflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$releaseReadinessScriptPath = Join-Path $repoRoot 'scripts/Resolve-CompareVIHistoryReleasePublishReadiness.ps1'
$readmePath = Join-Path $repoRoot 'README.md'
$exampleTargetsPath = Join-Path $repoRoot 'docs/examples/comparevi-history-consumer-targets.json'
$examplePrPolicyPath = Join-Path $repoRoot 'docs/examples/comparevi-history-pr-policy.json'
$examplePrPolicyV2Path = Join-Path $repoRoot 'docs/examples/comparevi-history-pr-policy-v2.json'
$exampleAgentCanaryPolicyPath = Join-Path $repoRoot 'docs/examples/comparevi-history-agent-canary-policy.json'
$actionPath = Join-Path $repoRoot 'action.yml'

function Assert-Match {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Content -notmatch $Pattern) {
    throw $Message
  }
}

function Assert-NotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Content -match $Pattern) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Actual,
    [Parameter(Mandatory = $true)]
    [string]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', actual '$Actual'."
  }
}

function Assert-MatchCount {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [int]$ExpectedCount,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  $actualCount = [regex]::Matches($Content, $Pattern).Count
  if ($actualCount -ne $ExpectedCount) {
    throw "$Message Expected '$ExpectedCount', actual '$actualCount'."
  }
}

$manualTemplate = Get-Content -LiteralPath $manualTemplatePath -Raw
$pullRequestTemplate = Get-Content -LiteralPath $pullRequestTemplatePath -Raw
$pullRequestAutoTemplate = Get-Content -LiteralPath $pullRequestAutoTemplatePath -Raw
$pullRequestPublishTemplate = Get-Content -LiteralPath $pullRequestPublishTemplatePath -Raw
$agentCanaryTemplate = Get-Content -LiteralPath $agentCanaryTemplatePath -Raw
$commentTemplate = Get-Content -LiteralPath $commentTemplatePath -Raw
$manualExplorationTemplate = Get-Content -LiteralPath $manualExplorationTemplatePath -Raw
$safeTemplates = Get-Content -LiteralPath $safeTemplatesPath -Raw
$publishedValidationWorkflow = Get-Content -LiteralPath $publishedValidationWorkflowPath -Raw
$pullRequestWorkflow = Get-Content -LiteralPath $pullRequestWorkflowPath -Raw
$pullRequestAutoWorkflow = Get-Content -LiteralPath $pullRequestAutoWorkflowPath -Raw
$pullRequestPublishWorkflow = Get-Content -LiteralPath $pullRequestPublishWorkflowPath -Raw
$agentCanaryWorkflow = Get-Content -LiteralPath $agentCanaryWorkflowPath -Raw
$manualExplorationWorkflow = Get-Content -LiteralPath $manualExplorationWorkflowPath -Raw
$smokeWorkflow = Get-Content -LiteralPath $smokeWorkflowPath -Raw
$releaseWorkflow = Get-Content -LiteralPath $releaseWorkflowPath -Raw
$releaseReadinessScript = Get-Content -LiteralPath $releaseReadinessScriptPath -Raw
$readme = Get-Content -LiteralPath $readmePath -Raw
$exampleTargets = Get-Content -LiteralPath $exampleTargetsPath -Raw
$examplePrPolicy = Get-Content -LiteralPath $examplePrPolicyPath -Raw
$examplePrPolicyV2 = Get-Content -LiteralPath $examplePrPolicyV2Path -Raw
$exampleAgentCanaryPolicy = Get-Content -LiteralPath $exampleAgentCanaryPolicyPath -Raw
$actionYaml = Get-Content -LiteralPath $actionPath -Raw

Assert-Match -Content $manualTemplate -Pattern '(?m)^\s*runs-on:\s+ubuntu-latest\s*$' -Message 'Manual template must use ubuntu-latest.'
Assert-Match -Content $manualTemplate -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Manual template must pin the NI Linux image.'
Assert-Match -Content $manualTemplate -Pattern 'docker pull "\$COMPAREVI_NI_LINUX_IMAGE"' -Message 'Manual template must pre-pull the NI Linux image.'
Assert-Match -Content $manualTemplate -Pattern 'invoke_script_path:\s+Tooling/Invoke-CompareVIHistoryHostedNILinux\.ps1' -Message 'Manual template must use the hosted NI Linux invoke adapter.'
Assert-Match -Content $manualTemplate -Pattern 'target_spec_path:\s+\.github/comparevi-history-targets\.json' -Message 'Manual template must consume the checked-in target catalog.'
Assert-Match -Content $manualTemplate -Pattern 'target_id:\s+\$\{\{ inputs\.target_id \}\}' -Message 'Manual template must route a target id into the action.'
Assert-Match -Content $manualTemplate -Pattern 'reviewer_surface:\s+manual' -Message 'Manual template must declare the manual reviewer surface.'
Assert-Match -Content $manualTemplate -Pattern 'public-step-summary-path' -Message 'Manual template must consume the action-owned public step summary output.'
Assert-NotMatch -Content $manualTemplate -Pattern '## comparevi-history manual PR diagnostics' -Message 'Manual template must not rebuild the diagnostics summary inline.'

Assert-Match -Content $pullRequestTemplate -Pattern 'LabVIEW-Community-CI-CD/comparevi-history/\.github/workflows/pull-request-diagnostics\.yml@v1' -Message 'Pull request template must call the reusable workflow surface.'
Assert-Match -Content $pullRequestTemplate -Pattern 'target_spec_path:\s+\.github/comparevi-history-targets\.json' -Message 'Pull request template must consume the checked-in target catalog.'
Assert-Match -Content $pullRequestTemplate -Pattern 'pr_policy_path:\s+\.github/comparevi-history-pr-policy\.json' -Message 'Pull request template must consume the checked-in PR policy.'
Assert-Match -Content $pullRequestTemplate -Pattern 'results_dir:\s+tests/results/pr-diagnostics/history' -Message 'Pull request template must keep the standard PR diagnostics results root.'
Assert-Match -Content $pullRequestTemplate -Pattern 'platform_ref:\s+v1' -Message 'Pull request template must keep platform_ref aligned with the workflow pin.'
Assert-NotMatch -Content $pullRequestTemplate -Pattern 'invoke_script_path:' -Message 'Pull request template must not own the hosted invoke adapter path.'

Assert-Match -Content $pullRequestAutoTemplate -Pattern 'LabVIEW-Community-CI-CD/comparevi-history/\.github/workflows/pull-request-diagnostics-auto\.yml@v1' -Message 'Automatic changed-VI template must call the dynamic reusable workflow surface.'
Assert-Match -Content $pullRequestAutoTemplate -Pattern 'pr_policy_path:\s+\.github/comparevi-history-pr-policy\.json' -Message 'Automatic changed-VI template must consume the checked-in PR policy.'
Assert-Match -Content $pullRequestAutoTemplate -Pattern 'results_dir:\s+tests/results/pr-diagnostics/history' -Message 'Automatic changed-VI template must keep the standard PR diagnostics results root.'
Assert-Match -Content $pullRequestAutoTemplate -Pattern 'platform_ref:\s+v1' -Message 'Automatic changed-VI template must keep platform_ref aligned with the workflow pin.'
Assert-Match -Content $pullRequestAutoTemplate -Pattern '(?m)^\s*pull_request:\s*$' -Message 'Automatic changed-VI template must trigger on pull_request.'
Assert-Match -Content $pullRequestAutoTemplate -Pattern 'release/\*' -Message 'Automatic changed-VI template must cover release branches.'
Assert-Match -Content $pullRequestAutoTemplate -Pattern 'feature/\*' -Message 'Automatic changed-VI template must cover feature branches.'
Assert-Match -Content $pullRequestAutoTemplate -Pattern 'hotfix/\*' -Message 'Automatic changed-VI template must cover hotfix branches.'
Assert-NotMatch -Content $pullRequestAutoTemplate -Pattern 'target_spec_path:' -Message 'Automatic changed-VI template must not require a target catalog.'

Assert-Match -Content $pullRequestPublishTemplate -Pattern 'LabVIEW-Community-CI-CD/comparevi-history/\.github/workflows/pull-request-diagnostics-publish\.yml@v1' -Message 'Publication template must call the reusable publication workflow surface.'
Assert-Match -Content $pullRequestPublishTemplate -Pattern '(?m)^\s*workflow_run:\s*$' -Message 'Publication template must trigger on workflow_run.'
Assert-Match -Content $pullRequestPublishTemplate -Pattern '(?m)^\s*actions:\s+read\s*$' -Message 'Publication template must request actions: read.'
Assert-Match -Content $pullRequestPublishTemplate -Pattern '(?m)^\s*contents:\s+write\s*$' -Message 'Publication template must request contents: write for preview image publication.'
Assert-Match -Content $pullRequestPublishTemplate -Pattern '(?m)^\s*pull-requests:\s+write\s*$' -Message 'Publication template must request pull-requests: write.'
Assert-Match -Content $pullRequestPublishTemplate -Pattern 'workflow_run_id:\s+\$\{\{ github\.event\.workflow_run\.id \}\}' -Message 'Publication template must route workflow_run.id into the reusable workflow.'
Assert-Match -Content $pullRequestPublishTemplate -Pattern 'artifact_name:\s+comparevi-history-pr-diagnostics-\$\{\{ github\.event\.workflow_run\.id \}\}' -Message 'Publication template must resolve the deterministic execution artifact name.'

Assert-Match -Content $agentCanaryTemplate -Pattern 'LabVIEW-Community-CI-CD/comparevi-history/\.github/workflows/pull-request-diagnostics-canary-evaluate\.yml@v1' -Message 'Agent canary template must call the reusable evaluation workflow surface.'
Assert-Match -Content $agentCanaryTemplate -Pattern '(?m)^\s*workflow_run:\s*$' -Message 'Agent canary template must trigger on workflow_run.'
Assert-Match -Content $agentCanaryTemplate -Pattern '(?m)^\s*actions:\s+read\s*$' -Message 'Agent canary template must request actions: read.'
Assert-Match -Content $agentCanaryTemplate -Pattern '(?m)^\s*contents:\s+read\s*$' -Message 'Agent canary template must request contents: read.'
Assert-Match -Content $agentCanaryTemplate -Pattern '(?m)^\s*pull-requests:\s+read\s*$' -Message 'Agent canary template must request pull-requests: read so labels and draft state can be evaluated deterministically.'
Assert-Match -Content $agentCanaryTemplate -Pattern 'workflow_run_id:\s+\$\{\{ github\.event\.workflow_run\.id \}\}' -Message 'Agent canary template must route workflow_run.id into the reusable evaluator.'
Assert-NotMatch -Content $agentCanaryTemplate -Pattern '(?m)^\s*artifact_name:\s*$' -Message 'Agent canary template should let the reusable evaluator resolve the publisher artifact from the completed workflow run.'
Assert-Match -Content $agentCanaryTemplate -Pattern 'canary_policy_path:\s+\.github/comparevi-history-agent-canary\.json' -Message 'Agent canary template must consume the checked-in agent-canary policy.'
Assert-Match -Content $agentCanaryTemplate -Pattern 'platform_ref:\s+v1' -Message 'Agent canary template must keep platform_ref aligned with the workflow pin.'

Assert-Match -Content $manualExplorationTemplate -Pattern '(?m)^\s*vi_path:\s*$' -Message 'Manual exploration template must accept vi_path.'
Assert-Match -Content $manualExplorationTemplate -Pattern '(?m)^\s*default:\s+develop\s*$' -Message 'Manual exploration template must default the consumer ref to develop.'
Assert-Match -Content $manualExplorationTemplate -Pattern '(?m)^\s*default:\s+full\s*$' -Message 'Manual exploration template must default to the unsuppressed full mode.'
Assert-Match -Content $manualExplorationTemplate -Pattern '(?m)^\s*default:\s+include\s*$' -Message 'Manual exploration template must default to in-band noise handling.'
Assert-Match -Content $manualExplorationTemplate -Pattern 'LabVIEW-Community-CI-CD/comparevi-history/\.github/workflows/manual-vi-exploration\.yml@v1' -Message 'Manual exploration template must call the reusable workflow surface.'
Assert-Match -Content $manualExplorationTemplate -Pattern 'platform_ref:\s+v1' -Message 'Manual exploration template must keep platform_ref aligned with the workflow pin.'
Assert-NotMatch -Content $manualExplorationTemplate -Pattern 'target_id:' -Message 'Manual exploration template must not require a curated target id.'
Assert-NotMatch -Content $manualExplorationTemplate -Pattern 'target_spec_path:' -Message 'Manual exploration template must not require a curated target spec.'

Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*workflow_call:\s*$' -Message 'Manual exploration workflow must be reusable.'
Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*workflow_dispatch:\s*$' -Message 'Manual exploration workflow must remain manually dispatchable.'
Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*vi_path:\s*$' -Message 'Manual exploration workflow must accept vi_path.'
Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*default:\s+full\s*$' -Message 'Manual exploration workflow must default to the unsuppressed full mode.'
Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*default:\s+include\s*$' -Message 'Manual exploration workflow must default to in-band noise handling.'
Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Manual exploration workflow must pin the NI Linux image.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Write-CompareVIHistoryRevisionCatalog\.ps1' -Message 'Manual exploration workflow must write the revision catalog.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Write-CompareVIHistoryChunkPlan\.ps1' -Message 'Manual exploration workflow must write the chunk plan.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'docker pull "\$COMPAREVI_NI_LINUX_IMAGE"' -Message 'Manual exploration workflow must pre-pull the NI Linux image.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Invoke-CompareVIHistoryChunkExecution\.ps1' -Message 'Manual exploration workflow must execute planned chunks.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Write-CompareVIHistoryExplorationBundle\.ps1' -Message 'Manual exploration workflow must write the exploration bundle.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Write-CompareVIHistoryExplorationRun\.ps1' -Message 'Manual exploration workflow must write the exploration run receipt.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'revision-catalog-path' -Message 'Manual exploration workflow must expose the revision catalog output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'results-root' -Message 'Manual exploration workflow must expose the resolved exploration results root.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'chunk-plan-path' -Message 'Manual exploration workflow must expose the chunk plan output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'execution-status' -Message 'Manual exploration workflow must expose the chunk execution status.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'bundle-status' -Message 'Manual exploration workflow must expose the bundle status.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'bundle-path' -Message 'Manual exploration workflow must expose the bundle path.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'exploration-run-path' -Message 'Manual exploration workflow must expose the exploration run output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'evidence-graph-path' -Message 'Manual exploration workflow must expose the canonical evidence graph output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'shared-evidence-path' -Message 'Manual exploration workflow must expose the shared evidence output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern "steps\.exploration\.outputs\['evidence-graph-path'\]" -Message 'Manual exploration workflow must upload the evidence graph artifact.'
Assert-Match -Content $manualExplorationWorkflow -Pattern "steps\.exploration\.outputs\['shared-evidence-path'\]" -Message 'Manual exploration workflow must upload the shared evidence artifact.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'index-md' -Message 'Manual exploration workflow must expose the index markdown output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'index-html' -Message 'Manual exploration workflow must expose the index HTML output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'timeline-md' -Message 'Manual exploration workflow must expose the timeline markdown output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'timeline-html' -Message 'Manual exploration workflow must expose the timeline HTML output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'platform_ref' -Message 'Manual exploration workflow must expose the platform_ref seam explicitly.'
Assert-Match -Content $manualExplorationWorkflow -Pattern "Split-Path -Parent '\$\{\{ steps\.catalog\.outputs\['revision-catalog-path'\] \}\}'" -Message 'Manual exploration workflow must derive the resolved results root from the revision catalog output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern "\$\{\{ steps\.results_root\.outputs\['results-root'\] \}\}" -Message 'Manual exploration workflow must route the resolved results root into later stages.'
Assert-MatchCount -Content $manualExplorationWorkflow -Pattern "'tests/results/ref-compare/history-exploration'" -ExpectedCount 1 -Message 'Manual exploration workflow must only use the relative results directory during catalog generation.'
Assert-Match -Content $manualExplorationWorkflow -Pattern "steps\.exploration\.outputs\['exploration-status'\] != 'succeeded'" -Message 'Manual exploration workflow must fail closed when exploration output is degraded.'

Assert-Match -Content $pullRequestWorkflow -Pattern '(?m)^\s*workflow_call:\s*$' -Message 'Pull request workflow must be reusable.'
Assert-Match -Content $pullRequestWorkflow -Pattern '(?m)^\s*target_spec_path:\s*$' -Message 'Pull request workflow must accept target_spec_path.'
Assert-Match -Content $pullRequestWorkflow -Pattern '(?m)^\s*pr_policy_path:\s*$' -Message 'Pull request workflow must accept pr_policy_path.'
Assert-Match -Content $pullRequestWorkflow -Pattern '(?m)^\s*allow_trusted_fork_execution:\s*$' -Message 'Pull request workflow must accept allow_trusted_fork_execution for maintainer-triggered fork fallback.'
Assert-Match -Content $pullRequestWorkflow -Pattern '(?m)^\s*default:\s+\.github/comparevi-history-targets\.json\s*$' -Message 'Pull request workflow must default to the checked-in target catalog path.'
Assert-Match -Content $pullRequestWorkflow -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Pull request workflow must pin the NI Linux image.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'Write-CompareVIHistoryPullRequestDiscovery\.ps1' -Message 'Pull request workflow must discover changed VI targets.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'Checkout trusted consumer base repository' -Message 'Pull request workflow must keep a trusted base checkout.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'Checkout pull request head repository' -Message 'Pull request workflow must keep a candidate head checkout.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'Invoke-CompareVIHistoryPullRequestDiagnostics\.ps1' -Message 'Pull request workflow must orchestrate matched-target diagnostics.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'Write-CompareVIHistoryPullRequestRun\.ps1' -Message 'Pull request workflow must write the aggregate PR run receipt.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'changed-vi-discovery-path' -Message 'Pull request workflow must expose the discovery receipt path.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'pr-run-path' -Message 'Pull request workflow must expose the aggregate PR run path.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'public-comment-path' -Message 'Pull request workflow must expose the deterministic PR comment body path.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'public-step-summary-path' -Message 'Pull request workflow must expose the deterministic step summary path.'
Assert-Match -Content $pullRequestWorkflow -Pattern 'comparevi-history-pr-diagnostics-' -Message 'Pull request workflow must upload PR diagnostics artifacts.'
Assert-Match -Content $pullRequestWorkflow -Pattern "steps\.aggregate\.outputs\['final-status'\] == 'failed'" -Message 'Pull request workflow must fail closed only on failed aggregate diagnostics.'
Assert-NotMatch -Content $pullRequestWorkflow -Pattern '(?m)^\s*pull-requests:\s+write\s*$' -Message 'Pull request workflow must not request PR comment publication permissions in this slice.'

Assert-Match -Content $pullRequestAutoWorkflow -Pattern '(?m)^\s*workflow_call:\s*$' -Message 'Automatic changed-VI workflow must be reusable.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern '(?m)^\s*pr_policy_path:\s*$' -Message 'Automatic changed-VI workflow must accept pr_policy_path.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Automatic changed-VI workflow must pin the NI Linux image.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern 'Write-CompareVIHistoryAutomaticPullRequestDiscovery\.ps1' -Message 'Automatic changed-VI workflow must use the v2 discovery writer.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern 'Invoke-CompareVIHistoryAutomaticPullRequestDiagnostics\.ps1' -Message 'Automatic changed-VI workflow must use the dynamic execution seam.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern 'Write-CompareVIHistoryAutomaticPullRequestRun\.ps1' -Message 'Automatic changed-VI workflow must write the aggregate v2 PR run receipt.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern 'artifact-name' -Message 'Automatic changed-VI workflow must expose the uploaded artifact name.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern 'index-markdown-path' -Message 'Automatic changed-VI workflow must expose the aggregate markdown index.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern 'index-html-path' -Message 'Automatic changed-VI workflow must expose the aggregate HTML index.'
Assert-Match -Content $pullRequestAutoWorkflow -Pattern "steps\.aggregate\.outputs\['final-status'\] == 'blocked'" -Message 'Automatic changed-VI workflow must fail closed on blocked aggregate diagnostics.'
Assert-NotMatch -Content $pullRequestAutoWorkflow -Pattern 'target_spec_path:' -Message 'Automatic changed-VI workflow must not accept a target catalog path.'
Assert-NotMatch -Content $pullRequestAutoWorkflow -Pattern 'max_pairs:' -Message 'Automatic changed-VI workflow must not surface pair caps in the dynamic path.'
Assert-NotMatch -Content $pullRequestAutoWorkflow -Pattern 'max_signal_pairs:' -Message 'Automatic changed-VI workflow must not surface signal-pair caps in the dynamic path.'

Assert-Match -Content $pullRequestPublishWorkflow -Pattern '(?m)^\s*workflow_call:\s*$' -Message 'Publication workflow must be reusable.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern '(?m)^\s*workflow_run_id:\s*$' -Message 'Publication workflow must accept workflow_run_id.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern '(?m)^\s*artifact_name:\s*$' -Message 'Publication workflow must accept artifact_name.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern '(?m)^\s*actions:\s+read\s*$' -Message 'Publication workflow must request actions: read.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern '(?m)^\s*contents:\s+write\s*$' -Message 'Publication workflow must request contents: write for preview image publication.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern '(?m)^\s*pull-requests:\s+write\s*$' -Message 'Publication workflow must request pull-requests: write.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern 'Publish-CompareVIHistoryPullRequestComment\.ps1' -Message 'Publication workflow must use the sticky-comment publisher.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern 'continue-on-error:\s+true' -Message 'Publication workflow must preserve outputs and receipts on publish failures.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern 'comparevi-history-pr-diagnostics-publish-' -Message 'Publication workflow must upload publication receipts.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern 'preview-publication-status' -Message 'Publication workflow must expose preview publication status outputs.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern 'preview-manifest-url' -Message 'Publication workflow must expose the preview manifest URL output.'
Assert-Match -Content $pullRequestPublishWorkflow -Pattern "steps\.publish\.outcome == 'failure'" -Message 'Publication workflow must fail closed on publish failures after receipts upload.'
Assert-NotMatch -Content $pullRequestPublishWorkflow -Pattern 'candidate-consumer' -Message 'Publication workflow must not check out or execute candidate PR code.'

Assert-Match -Content $agentCanaryWorkflow -Pattern '(?m)^\s*workflow_call:\s*$' -Message 'Agent canary workflow must be reusable.'
Assert-Match -Content $agentCanaryWorkflow -Pattern '(?m)^\s*workflow_run_id:\s*$' -Message 'Agent canary workflow must accept workflow_run_id.'
Assert-Match -Content $agentCanaryWorkflow -Pattern '(?m)^\s*artifact_name:\s*$' -Message 'Agent canary workflow must accept artifact_name.'
Assert-Match -Content $agentCanaryWorkflow -Pattern '(?m)^\s*canary_policy_path:\s*$' -Message 'Agent canary workflow must accept canary_policy_path.'
Assert-Match -Content $agentCanaryWorkflow -Pattern '(?m)^\s*actions:\s+read\s*$' -Message 'Agent canary workflow must request actions: read.'
Assert-Match -Content $agentCanaryWorkflow -Pattern '(?m)^\s*pull-requests:\s+read\s*$' -Message 'Agent canary workflow must request pull-requests: read.'
Assert-Match -Content $agentCanaryWorkflow -Pattern 'Write-CompareVIHistoryAgentCanaryEvaluation\.ps1' -Message 'Agent canary workflow must use the agent canary evaluator script.'
Assert-Match -Content $agentCanaryWorkflow -Pattern 'comparevi-history-pr-diagnostics-canary-' -Message 'Agent canary workflow must upload canary evaluation receipts.'
Assert-Match -Content $agentCanaryWorkflow -Pattern "steps\.evaluate\.outcome == 'failure'" -Message 'Agent canary workflow must fail closed on evaluator failures after receipts upload.'
Assert-NotMatch -Content $agentCanaryWorkflow -Pattern 'candidate-consumer' -Message 'Agent canary workflow must not check out or execute candidate PR code.'

Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*runs-on:\s+ubuntu-latest\s*$' -Message 'Comment-gated template must use ubuntu-latest.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*pull-requests:\s+write\s*$' -Message 'Comment-gated template must request pull-requests: write.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*DEFAULT_COMPARE_MODES:\s+attributes,front-panel,block-diagram\s*$' -Message 'Comment-gated template must default to explicit public modes only.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Comment-gated template must pin the NI Linux image.'
Assert-Match -Content $commentTemplate -Pattern 'docker pull "\$COMPAREVI_NI_LINUX_IMAGE"' -Message 'Comment-gated template must pre-pull the NI Linux image.'
Assert-Match -Content $commentTemplate -Pattern 'invoke_script_path:\s+Tooling/Invoke-CompareVIHistoryHostedNILinux\.ps1' -Message 'Comment-gated template must use the hosted NI Linux invoke adapter.'
Assert-Match -Content $commentTemplate -Pattern 'target-id=' -Message 'Comment-gated template must parse a target id from the slash command.'
Assert-Match -Content $commentTemplate -Pattern 'target_spec_path:\s+\.github/comparevi-history-targets\.json' -Message 'Comment-gated template must consume the checked-in target catalog.'
Assert-Match -Content $commentTemplate -Pattern 'reviewer_surface:\s+comment-gated' -Message 'Comment-gated template must declare the comment-gated reviewer surface.'
Assert-Match -Content $commentTemplate -Pattern 'public-comment-path' -Message 'Comment-gated template must publish the action-owned comment body.'
Assert-Match -Content $commentTemplate -Pattern 'public-step-summary-path' -Message 'Comment-gated template must publish the action-owned step summary.'
Assert-Match -Content $commentTemplate -Pattern 'Resource not accessible by integration' -Message 'Comment-gated template must recognize permission-denied PR comment failures.'
Assert-Match -Content $commentTemplate -Pattern 'PR comment publication was denied by the repository token' -Message 'Comment-gated template must warn on denied PR comment publication.'
Assert-Match -Content $commentTemplate -Pattern 'PR comment publication: `skipped`' -Message 'Comment-gated template must record skipped PR comment publication in the step summary.'
Assert-NotMatch -Content $commentTemplate -Pattern 'comparevi-history diagnostics finished for PR' -Message 'Comment-gated template must not rebuild the PR comment inline.'
Assert-NotMatch -Content $commentTemplate -Pattern '(?m)^\s*DEFAULT_COMPARE_MODES:\s+default,' -Message 'Comment-gated template must not default to aggregate public modes.'

Assert-Match -Content $exampleTargets -Pattern 'comparevi-history/consumer-targets@v1' -Message 'Example targets file must declare the consumer-targets schema.'
Assert-Match -Content $exampleTargets -Pattern '"publicModes"' -Message 'Example targets file must declare public modes.'
Assert-Match -Content $examplePrPolicy -Pattern 'comparevi-history/pr-policy@v1' -Message 'Example PR policy file must declare the pr-policy schema.'
Assert-Match -Content $examplePrPolicy -Pattern '"allowedTargetIds"' -Message 'Example PR policy file must declare target allowlists.'
Assert-Match -Content $examplePrPolicy -Pattern '"publicModes"' -Message 'Example PR policy file must declare public mode policy.'
Assert-Match -Content $examplePrPolicyV2 -Pattern 'comparevi-history/pr-policy@v2' -Message 'Example dynamic PR policy file must declare the v2 PR policy schema.'
Assert-Match -Content $examplePrPolicyV2 -Pattern '"selectionMode"\s*:\s*"dynamic-paths"' -Message 'Example dynamic PR policy file must opt into dynamic-path discovery.'
Assert-Match -Content $examplePrPolicyV2 -Pattern '"includePaths"\s*:\s*\[\s*"\*\*/\*\.vi"' -Message 'Example dynamic PR policy file must include all changed VI paths by default.'
Assert-Match -Content $examplePrPolicyV2 -Pattern '"maxChangedViCount"\s*:\s*10' -Message 'Example dynamic PR policy file must fail closed at ten changed VIs.'
Assert-Match -Content $examplePrPolicyV2 -Pattern '"noisePolicy"\s*:\s*"include"' -Message 'Example dynamic PR policy file must default to unsuppressed noise handling.'
Assert-Match -Content $examplePrPolicyV2 -Pattern '"forkBehavior"\s*:\s*"hosted-auto"' -Message 'Example dynamic PR policy file must allow hosted automatic fork execution.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern 'comparevi-history/agent-canary-policy@v1' -Message 'Example agent canary policy file must declare the agent-canary policy schema.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"branchPrefix"\s*:\s*"agent-canary/' -Message 'Example agent canary policy file must declare the canary branch prefix.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"requiredLabels"\s*:\s*\[\s*"agent-canary"' -Message 'Example agent canary policy file must declare the required canary label.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"canonicalPath"\s*:\s*"Tooling/comparevi-history-canary/CanaryProbe\.vi"' -Message 'Example agent canary policy file must bind the dedicated canary VI path.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"prMode"\s*:\s*"draft"' -Message 'Example agent canary policy file must require a draft canary PR.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"reviewerSurfaceContract"' -Message 'Example agent canary policy file must declare the reviewer-surface contract.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"requiredSurfaceKinds"\s*:\s*\[\s*"front-panel"\s*,\s*"block-diagram"' -Message 'Example agent canary policy file must require both reviewer surfaces.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"requiredMarkdownSections"\s*:\s*\[\s*"## Workspace summary"' -Message 'Example agent canary policy file must freeze workspace markdown sections.'
Assert-Match -Content $exampleAgentCanaryPolicy -Pattern '"maxCommentPreviewCards"\s*:\s*4' -Message 'Example agent canary policy file must cap reviewer comment preview cards.'
Assert-Match -Content $safeTemplates -Pattern 'attributes,front-panel,block-diagram' -Message 'Safe template docs must document the explicit public mode contract.'
Assert-Match -Content $safeTemplates -Pattern '\.github/comparevi-history-targets\.json' -Message 'Safe template docs must document the checked-in target catalog path.'
Assert-Match -Content $safeTemplates -Pattern '\.github/comparevi-history-pr-policy\.json' -Message 'Safe template docs must document the checked-in PR policy path.'
Assert-Match -Content $safeTemplates -Pattern 'public-comment-path' -Message 'Safe template docs must point consumers at the action-owned comment output.'
Assert-Match -Content $safeTemplates -Pattern 'public-step-summary-path' -Message 'Safe template docs must point consumers at the action-owned step summary output.'
Assert-Match -Content $safeTemplates -Pattern 'comparevi-history-pull-request-diagnostics-auto\.yml' -Message 'Safe template docs must document the dynamic changed-VI execution template.'
Assert-Match -Content $safeTemplates -Pattern 'comparevi-history-pull-request-diagnostics-publish\.yml' -Message 'Safe template docs must document the workflow_run publication template.'
Assert-Match -Content $safeTemplates -Pattern 'comparevi-history-agent-canary-evaluate\.yml' -Message 'Safe template docs must document the agent canary evaluation template.'
Assert-Match -Content $safeTemplates -Pattern 'comparevi-history-agent-canary-policy\.json' -Message 'Safe template docs must document the agent canary policy example.'
Assert-Match -Content $safeTemplates -Pattern 'reviewerSurfaceContract' -Message 'Safe template docs must document reviewer-surface canary invariants.'
Assert-Match -Content $safeTemplates -Pattern 'pr-preview-manifest\.json' -Message 'Safe template docs must document the preview manifest in the canary publication artifact.'
Assert-Match -Content $safeTemplates -Pattern 'dynamic-paths' -Message 'Safe template docs must document dynamic-path discovery.'
Assert-Match -Content $safeTemplates -Pattern 'workflow_run' -Message 'Safe template docs must document workflow_run publication.'
Assert-Match -Content $safeTemplates -Pattern 'hosted-auto' -Message 'Safe template docs must document hosted automatic fork execution.'
Assert-Match -Content $safeTemplates -Pattern 'sticky comment' -Message 'Safe template docs must document the sticky-comment publication surface.'
Assert-Match -Content $safeTemplates -Pattern 'agent-canary' -Message 'Safe template docs must document the dedicated agent-canary proof lane.'
Assert-Match -Content $publishedValidationWorkflow -Pattern '\.github/comparevi-history-targets\.json' -Message 'Published validation must synthesize a checked-in-style target catalog path.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'target_spec_path:\s+\.github/comparevi-history-targets\.json' -Message 'Published validation must route target_spec_path into the action.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'target_id:\s+published-consumer-target' -Message 'Published validation must route a stable target id into the action.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'history-summary-json' -Message 'Published validation must consume the action-owned history summary output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'shared-evidence-path' -Message 'Published validation must consume the shared evidence output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'public-comment-path' -Message 'Published validation must consume the action-owned public comment output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'public-step-summary-path' -Message 'Published validation must consume the action-owned public step summary output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern '(?m)^\s*default:\s+attributes,front-panel,block-diagram\s*$' -Message 'Published validation must default to explicit public modes only.'
Assert-NotMatch -Content $publishedValidationWorkflow -Pattern '(?m)^\s*default:\s+default,attributes,front-panel,block-diagram\s*$' -Message 'Published validation must not default to aggregate aliases for public modes.'
Assert-Match -Content $smokeWorkflow -Pattern 'comparevi-backend-ref\.txt' -Message 'Smoke workflow must resolve the repo-pinned backend release tag.'
Assert-Match -Content $releaseWorkflow -Pattern 'comparevi-backend-ref\.txt' -Message 'Release workflow must read comparevi-backend-ref.txt.'
Assert-Match -Content $releaseWorkflow -Pattern "tooling-source'\] -ne 'bundle'" -Message 'Release workflow must fail closed when the resolved backend is not a bundle release.'
Assert-Match -Content $releaseWorkflow -Pattern 'scripts/Resolve-CompareVIHistoryReleasePublishReadiness\.ps1' -Message 'Release workflow must check publish readiness against already-reviewed main content.'
Assert-Match -Content $releaseWorkflow -Pattern 'scripts/Publish-CompareVIHistoryReviewCompilerArtifact\.ps1' -Message 'Release workflow must package self-contained review compiler assets during publish.'
Assert-Match -Content $releaseWorkflow -Pattern 'release-assets/\*\.zip' -Message 'Release workflow must publish zipped review compiler assets.'
Assert-Match -Content $releaseWorkflow -Pattern 'release-assets/comparevi-history-review-compiler-release\.json' -Message 'Release workflow must publish the review compiler release manifest.'
Assert-Match -Content $releaseWorkflow -Pattern 'release-assets/SHA256SUMS\.txt' -Message 'Release workflow must publish review compiler checksums.'
Assert-Match -Content $releaseWorkflow -Pattern 'if \[ "\$current_head_sha" != "\$current_main_sha" \]; then' -Message 'Release workflow must verify publish still targets the current origin/main tip before tagging.'
Assert-Match -Content $releaseWorkflow -Pattern 'Published comment-gated template already points at' -Message 'Release notes must mention the published comment-gated template pin.'
Assert-Match -Content $releaseWorkflow -Pattern 'git push origin "refs/tags/\$IMMUTABLE_TAG"' -Message 'Release workflow must push only the immutable tag during publish.'
Assert-Match -Content $releaseWorkflow -Pattern '(?s)uses:\s+\./\.github/workflows/published-consumer-validation\.yml.*?compare_modes:\s+attributes,front-panel,block-diagram' -Message 'Release workflow must invoke published-consumer validation with explicit public modes only.'
Assert-NotMatch -Content $releaseWorkflow -Pattern '(?s)uses:\s+\./\.github/workflows/published-consumer-validation\.yml.*?compare_modes:\s+default,attributes,front-panel,block-diagram' -Message 'Release workflow must not invoke published-consumer validation with aggregate aliases.'
Assert-NotMatch -Content $releaseWorkflow -Pattern 'git push --atomic origin HEAD:main' -Message 'Release workflow must not push a fresh commit directly to protected main during publish.'
Assert-Match -Content $releaseReadinessScript -Pattern 'Sync-CompareVIHistoryPublishedTemplates\.ps1' -Message 'Release readiness helper must derive desired publish content through the published template sync script.'
Assert-Match -Content $actionYaml -Pattern '(?s)id:\s+public_run.*if:\s+\$\{\{\s*always\(\)\s*&&\s*steps\.request\.outcome == ''success''\s*&&\s*steps\.request\.outputs\[''request-path''\]\s*!=\s*''''\s*\}\}' -Message 'Action public-run writer must only run when the request receipt exists.'
Assert-Match -Content $actionYaml -Pattern 'shared-evidence-path' -Message 'Action must expose the shared evidence output.'
Assert-Match -Content $actionYaml -Pattern 'mode-summary-json-path' -Message 'Action must expose the machine-readable mode summary output.'
Assert-Match -Content $readme -Pattern 'comparevi-history/consumer-targets@v1' -Message 'README must document the target catalog contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/public-run@v1' -Message 'README must document the public run contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/shared-evidence@v1' -Message 'README must document the shared evidence contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/changed-vi-discovery@v1' -Message 'README must document the changed-VI discovery contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/pr-policy@v1' -Message 'README must document the PR policy contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/pr-run@v1' -Message 'README must document the aggregate pull-request run contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/changed-vi-discovery@v2' -Message 'README must document the dynamic changed-VI discovery contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/pr-policy@v2' -Message 'README must document the dynamic PR policy contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/pr-run@v2' -Message 'README must document the dynamic aggregate pull-request run contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/review-bundle@v1' -Message 'README must document the compiled review bundle contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/review-compiler-release@v1' -Message 'README must document the compiled review compiler release contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/pr-comment-publication@v1' -Message 'README must document the PR comment publication contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/agent-canary-policy@v1' -Message 'README must document the agent-canary policy contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/agent-canary-evaluation@v1' -Message 'README must document the agent-canary evaluation contract.'
Assert-Match -Content $readme -Pattern 'reviewerSurfaceContract' -Message 'README must document the reviewer-surface canary contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/revision-catalog@v1' -Message 'README must document the revision catalog contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/exploration-run@v1' -Message 'README must document the exploration run contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/evidence-graph@v1' -Message 'README must document the canonical evidence graph contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/corpus-index@v1' -Message 'README must document the corpus index contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/corpus-page@v1' -Message 'README must document the corpus page contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/downstream-processing-manifest@v1' -Message 'README must document the downstream processing manifest contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/downstream-processor-summary@v1' -Message 'README must document the downstream processor summary contract.'
Assert-Match -Content $readme -Pattern 'modes=full' -Message 'README must document the raw manual exploration mode default.'
Assert-Match -Content $readme -Pattern 'noise_policy=include' -Message 'README must document the raw manual exploration noise-policy default.'
Assert-Match -Content $readme -Pattern 'Invoke-CompareVIHistoryLocalReview\.ps1' -Message 'README must document the local-review facade entrypoint.'
Assert-Match -Content $readme -Pattern 'comparevi-history/local-review@v1' -Message 'README must document the local-review receipt contract.'
Assert-Match -Content $readme -Pattern 'tests/results/local-review' -Message 'README must document the default local-review results root.'
Assert-Match -Content $readme -Pattern 'local-review-summary\.md' -Message 'README must document the local-review summary output.'
Assert-Match -Content $readme -Pattern 'latest immutable `comparevi-history` release' -Message 'README must document the released compiler default for local-review.'
Assert-Match -Content $readme -Pattern 'Invoke-CompareVIHistoryLocalProof\.ps1' -Message 'README must document the local-proof gate entrypoint.'
Assert-Match -Content $readme -Pattern 'comparevi-history/local-proof@v1' -Message 'README must document the local-proof receipt contract.'
Assert-Match -Content $readme -Pattern 'tests/results/local-proof' -Message 'README must document the default local-proof results root.'
Assert-Match -Content $readme -Pattern 'local-proof-summary\.md' -Message 'README must document the local-proof summary output.'
Assert-Match -Content $readme -Pattern 'current branch compiler' -Message 'README must explain that local-proof exercises the current branch compiler path.'
Assert-Match -Content $readme -Pattern 'structured `comparisonPairs` separately' -Message 'README must document structured comparison-pair outputs for manual exploration.'
Assert-Match -Content $readme -Pattern 'evidence-graph\.json' -Message 'README must document the canonical evidence graph output.'
Assert-Match -Content $readme -Pattern 'primary human review surfaces' -Message 'README must document the primary human review role of the index surfaces.'
Assert-Match -Content $readme -Pattern 'continuity segment, mode, comparison pair, and chunk' -Message 'README must document deterministic index navigation axes.'
Assert-Match -Content $readme -Pattern 'mode-summary\.json' -Message 'README must document the machine-readable mode summary output.'
Assert-Match -Content $readme -Pattern 'index\.md' -Message 'README must document the index markdown output.'
Assert-Match -Content $readme -Pattern 'index\.html' -Message 'README must document the index HTML output.'
Assert-Match -Content $readme -Pattern 'timeline\.md' -Message 'README must document the timeline markdown output.'
Assert-Match -Content $readme -Pattern 'timeline\.html' -Message 'README must document the timeline HTML output.'
Assert-Match -Content $readme -Pattern 'manual-vi-exploration-bundle\.zip' -Message 'README must document the manual exploration bundle.'
Assert-Match -Content $readme -Pattern 'page-ordinal' -Message 'README must document the page-ordinal continuation contract.'
Assert-Match -Content $readme -Pattern 'Write-CompareVIHistoryDownstreamProcessorSummary\.ps1' -Message 'README must document the first downstream processor entrypoint.'
Assert-Match -Content $readme -Pattern 'without markdown and HTML\s+scraping' -Message 'README must document that the downstream processor avoids markdown and HTML scraping.'
Assert-Match -Content $readme -Pattern 'tests/fixtures/corpus-pilot-v1' -Message 'README must document the canonical corpus pilot golden baseline path.'
Assert-Match -Content $readme -Pattern 'tests/fixtures/reviewer-workspace-v1' -Message 'README must document the canonical reviewer workspace golden baseline path.'
Assert-Match -Content $readme -Pattern 'tests/fixtures/review-bundle-v1' -Message 'README must document the canonical review-bundle golden baseline path.'
Assert-Match -Content $readme -Pattern 'VIP_Post-Install Custom Action\.vi' -Message 'README must identify the first corpus pilot targets.'
Assert-Match -Content $readme -Pattern 'VIP_Pre-Install Custom Action\.vi' -Message 'README must identify the first corpus pilot targets.'
Assert-Match -Content $readme -Pattern 'bounded teaser surface' -Message 'README must document that the step summary remains bounded.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-manual-vi-exploration\.yml' -Message 'README must point to the manual exploration wrapper example.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-pull-request-diagnostics\.yml' -Message 'README must point to the pull request diagnostics wrapper example.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-pull-request-diagnostics-auto\.yml' -Message 'README must point to the automatic changed-VI execution wrapper example.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-pull-request-diagnostics-publish\.yml' -Message 'README must point to the PR comment publication wrapper example.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-agent-canary-evaluate\.yml' -Message 'README must point to the agent canary evaluation wrapper example.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-pr-policy\.json' -Message 'README must point to the PR policy example.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-pr-policy-v2\.json' -Message 'README must point to the dynamic PR policy example.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-agent-canary-policy\.json' -Message 'README must point to the agent canary policy example.'
Assert-Match -Content $readme -Pattern 'hosted NI Linux container path wired by a repo-local adapter' -Message 'README must document the hosted NI Linux adapter path.'
Assert-Match -Content $readme -Pattern 'public-comment-path' -Message 'README must document the action-owned public comment output.'
Assert-Match -Content $readme -Pattern 'shared-evidence\.json' -Message 'README must document the shared evidence output.'
Assert-Match -Content $readme -Pattern 'changed-vi-discovery\.json' -Message 'README must document the changed-VI discovery output.'
Assert-Match -Content $readme -Pattern 'pr-run\.json' -Message 'README must document the aggregate PR run output.'
Assert-Match -Content $readme -Pattern 'same-repo pull requests can auto-run immediately' -Message 'README must document same-repo automatic PR execution.'
Assert-Match -Content $readme -Pattern 'cross-repository and fork pull requests fail closed' -Message 'README must document blocked cross-repository PR execution.'
Assert-Match -Content $readme -Pattern 'dynamic-paths' -Message 'README must document dynamic-path discovery for changed VIs.'
Assert-Match -Content $readme -Pattern 'sticky PR comment' -Message 'README must document sticky PR comment publication.'
Assert-Match -Content $readme -Pattern 'workflow_run' -Message 'README must document workflow_run-based publication.'
Assert-Match -Content $readme -Pattern 'COMPAREVI_HISTORY_REVIEW_COMPILER_PATH' -Message 'README must document the packaged review compiler environment override.'
Assert-Match -Content $readme -Pattern 'CompilerPath' -Message 'README must document the packaged review compiler path override.'
Assert-Match -Content $readme -Pattern 'comparevi-history-review-compiler-v' -Message 'README must document the released review compiler asset names.'
Assert-Match -Content $readme -Pattern 'comparevi-history-review-compiler-release\.json' -Message 'README must document the review compiler release manifest asset.'
Assert-Match -Content $readme -Pattern 'SHA256SUMS\.txt' -Message 'README must document the review compiler checksum asset.'
Assert-Match -Content $readme -Pattern 'long-lived draft PR' -Message 'README must document the long-lived draft PR canary operating model.'
Assert-Match -Content $readme -Pattern 'same-repo only' -Message 'README must document the same-repo-only canary pilot boundary.'
Assert-Match -Content $readme -Pattern 'agent-canary/' -Message 'README must document the canary branch prefix.'
Assert-Match -Content $readme -Pattern 'CompareVI History Pull Request Diagnostics Publish' -Message 'README must document the publish workflow dependency for canary evaluation.'
Assert-Match -Content $readme -Pattern 'selectedTargets' -Message 'README must document selectedTargets in the v2 discovery receipt.'
Assert-Match -Content $readme -Pattern 'maxChangedViCount = 10' -Message 'README must document the ten-VI overflow contract for the dynamic PR surface.'
Assert-Match -Content $readme -Pattern 'attributes`, `front-panel`, and `block-diagram' -Message 'README must document explicit public modes only.'
Assert-Match -Content $readme -Pattern 'comparevi-history/issues/24' -Message 'README must point at the comparevi-history platform-boundary epic.'
Assert-Match -Content $readme -Pattern 'merge a\s+prep PR first' -Message 'README must explain the protected-main release prep requirement.'
Assert-NotMatch -Content $readme -Pattern 'compare-vi-cli-action/issues/841' -Message 'README must not point at the legacy compare-vi-cli-action tracking epic.'

$facadeRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*FACADE_REF:\s*(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$usesRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*uses:\s+LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$actionRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*ACTION_REF:\s+LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$docsRefMatch = [regex]::Match($safeTemplates, 'LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)')

foreach ($match in @($facadeRefMatch, $usesRefMatch, $actionRefMatch, $docsRefMatch)) {
  if (-not $match.Success) {
    throw 'Failed to resolve the published immutable tag across the comment-gated template contract.'
  }
}

$immutableTag = $facadeRefMatch.Groups[1].Value
Assert-Equal -Actual $usesRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Comment-gated template uses: pin mismatch.'
Assert-Equal -Actual $actionRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Comment-gated template ACTION_REF mismatch.'
Assert-Equal -Actual $docsRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Safe template docs immutable tag mismatch.'
