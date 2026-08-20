# Encodes CodeQL's `actions/missing-workflow-permissions` rule as a test.
#
# A workflow that declares no `permissions:` runs with whatever the repo or org
# default happens to be — historically write-all. The alert was open fleet-wide:
# deploy.yml, crawler.yml and check_data.yml in at least seven relaton-data-*
# repos, plus this repo's own ci-lint/ci-spec/ci-repo-watcher.
#
# None of that could be fixed where it was flagged. Every flagged data-repo file
# is Cimas-generated, so a hand-edit there is reverted by the next `cimas sync`;
# and it cannot be fixed in the reusable workflows either, because a called
# workflow's `permissions:` can only *downgrade* what the caller granted. CodeQL
# knows this and deliberately skips `workflow_call`-only workflows. So the grant
# has to live on the caller, and the callers are the templates in this repo.
#
# The two sweeps below make the whole class a test failure rather than a list of
# instances someone fixed once. Both are silent when broken: nothing goes red in
# CI, the token is just wider (or narrower) than intended.
RSpec.describe "workflow token grants" do
  repo_root = File.expand_path("..", __dir__)

  # CodeQL's condition, and GitHub's: a workflow-level block covers every job, or
  # each job carries its own. Either satisfies the rule; requiring one shape
  # would force gh-actions/master/rake.yml's existing workflow-level block to
  # move for no benefit.
  #
  # An empty block is rejected as well as a missing one. `permissions: {}` passes
  # CodeQL — it is the maximally restrictive grant — but here it would mean a
  # caller handing the workflow it calls a token with every scope set to `none`,
  # which is the same silent late failure a missing block risks, just inverted.
  declares_grant = lambda do |doc|
    granted = lambda do |block|
      block.is_a?(String) ? !block.empty? : !(block || {}).empty?
    end

    next granted.call(doc["permissions"]) if doc.key?("permissions")

    jobs = doc["jobs"] || {}
    !jobs.empty? && jobs.values.all? do |job|
      job.is_a?(Hash) && job.key?("permissions") && granted.call(job["permissions"])
    end
  end

  describe "every Cimas-synced caller template" do
    # Derived from cimas.yml rather than globbed, for the same reason
    # spec/cimas_data_pages_spec.rb derives it: the templates that matter are the
    # ones Cimas actually copies into other repos. A template nobody syncs is
    # dead config; one that is synced is copied byte-for-byte into every mapped
    # repo, so its grant is the grant the whole fleet runs under.
    cimas = YAML.safe_load_file(File.join(repo_root, "cimas-config/cimas.yml"))
    templates = cimas.fetch("repositories").values.compact
                     .flat_map { |r| (r["files"] || {}).values }
                     .uniq.select { |src| %w[.yml .yaml].include?(File.extname(src)) }
                     .sort

    it "is a non-empty list" do
      # Guards the sweep itself: a cimas.yml restructure that broke the
      # derivation would otherwise turn every example below into a vacuous pass.
      expect(templates).not_to be_empty
    end

    templates.each do |src|
      it "#{src} declares a permissions block" do
        doc = YAML.safe_load_file(File.join(repo_root, "cimas-config", src)) || {}

        expect(declares_grant.call(doc)).to be(true),
                                            "#{src} is copied into every mapped repo as a " \
                                            "top-level workflow, so it runs with the repo's " \
                                            "default GITHUB_TOKEN scope unless it says " \
                                            "otherwise. Declare `permissions:` on the workflow " \
                                            "or on every job — and make it the UNION of what " \
                                            "the called workflow's jobs request, not the " \
                                            "narrowest thing that parses."
      end
    end

    # Presence is not enough. The sweep above would still pass if a "tighten the
    # permissions" pass narrowed a grant to something the called workflow cannot
    # run under — which is the *other* half of this failure mode, and the more
    # expensive half, because it fails late and loudly in every synced repo at
    # once rather than quietly widening a token.
    #
    # deploy.yml and crawler.yml are pinned in
    # spec/data_deploy_caller_template_spec.rb, keep-alive.yml below. These are
    # the rest, so every synced template has its exact grant written down
    # somewhere.
    expected = {
      # rake.yml: pre-existing, and load-bearing — generic-rake.yml's
      # `tests-passed` job fires a repository-dispatch, which needs contents.
      "gh-actions/master/rake.yml" => { "contents" => "write" },
      # release.yml: narrowing this fails the publish step *after* the version
      # bump has been committed and tagged. See the note in the template about
      # `packages: write` being an inherited over-grant.
      "gh-actions/master/release.yml" => {
        "id-token" => "write", "contents" => "write", "packages" => "write"
      },
      "gh-actions/data/check_data.yml" => { "contents" => "read" },
      "gh-actions/model/make.yml" => { "contents" => "read" },
    }.freeze

    expected.each do |src, grant|
      it "#{src} grants exactly #{grant.inspect}" do
        doc = YAML.safe_load_file(File.join(repo_root, "cimas-config", src))
        # Wherever it is declared: these templates are all single-job, so a
        # workflow-level block and a job-level one are equivalent in effect.
        declared = doc["permissions"] || doc.fetch("jobs").values.first["permissions"]

        expect(declared).to eq(grant)
      end
    end
  end

  describe "every workflow this repo runs itself" do
    # The reusables here are `workflow_call`-only and correctly leave the grant to
    # their callers — CodeQL skips exactly that set, so this sweep does too. What
    # is left is the hand-written ones that actually run in this repo.
    #
    # ci-repo-watcher.yml is deliberately NOT skipped: it carries `schedule` and
    # `workflow_dispatch` alongside `workflow_call`, so it runs here on a daily
    # cron and needs a grant of its own.
    # Both extensions, matching the template sweep above and GitHub itself, which
    # runs `.yaml` workflows exactly like `.yml` ones. Globbing only `.yml` would
    # let a `codeql.yaml` reopen the very alert this file exists to close, with
    # the suite still green and nothing to say the file was never looked at.
    workflows = Dir[File.join(repo_root, ".github/workflows/*.{yml,yaml}")].sort

    it "is a non-empty list" do
      expect(workflows).not_to be_empty
    end

    workflows.each do |path|
      name = File.basename(path)

      it "#{name} declares a permissions block, or is reusable-only" do
        doc = YAML.safe_load_file(path)
        # Psych reads the unquoted `on:` key as YAML 1.1 boolean true.
        triggers = doc.fetch(true)
        next if triggers.keys == ["workflow_call"]

        expect(declares_grant.call(doc)).to be(true),
                                            "#{name} is triggered by #{triggers.keys.join(', ')} " \
                                            "in this repo, so it runs with the default " \
                                            "GITHUB_TOKEN scope unless it declares one."
      end
    end
  end

  describe "cimas-config/gh-actions/master/keep-alive.yml" do
    # This template silently drifted away from what is deployed. All three
    # regressions below were live in the template while the data repos carried
    # the fixed version by hand — so the next `cimas sync` would have reverted a
    # CodeQL alert that reads `fixed` in six repos, with nothing red to say so.
    # That is the failure mode a hand-edit in a synced destination always has,
    # and the reason each difference is pinned separately here.
    template = YAML.safe_load_file(File.join(repo_root, "cimas-config/gh-actions/master/keep-alive.yml"))

    it "grants actions: write" do
      # Not an over-grant: re-enabling workflows through the Actions API
      # (`gh api -X PUT /repos/.../actions/workflows/<id>/enable`) is the entire
      # job. Workflow-level rather than per-job, to match what is deployed so a
      # sync stays a functional no-op.
      expect(template.fetch("permissions")).to eq("actions" => "write")
    end

    it "can still be run by hand" do
      # A keep-alive whose only trigger is a monthly cron is precisely the
      # workflow GitHub disables for inactivity — and then there is no way to
      # start it again from the UI.
      expect(template.fetch(true)).to have_key("workflow_dispatch")
    end

    it "calls this repo's own keep-alive workflow" do
      # Every deployed copy points here rather than at metanorma/ci: the fleet
      # was moved onto support's version deliberately, and only the template
      # lagged. Asserted together with the file's existence, since a `uses:`
      # naming a workflow that is not here fails at run time, in a monthly cron
      # nobody watches.
      expect(template.fetch("jobs").fetch("keep-alive").fetch("uses"))
        .to eq("relaton/support/.github/workflows/keep-alive.yml@main")
      expect(File).to exist(File.join(repo_root, ".github/workflows/keep-alive.yml"))
    end
  end
end
