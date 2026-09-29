# PSScriptAnalyzer configuration. Invoke via gates.ps1 (which CI also
# runs), never by hand-tuning the lint command.
@{
  Severity     = @('Error', 'Warning')
  ExcludeRules = @(
    # Pester 5 runs BeforeAll/It blocks in scopes the static analyzer
    # cannot see: it flags Describe-shared variables as assigned-but-unused
    # even though every run proves they are read. The suite itself is the
    # check for these (an unset variable fails its test).
    'PSUseDeclaredVarsMoreThanAssignments'
  )
}
