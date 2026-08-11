# Guards the reusable Pages workflow's caller contract: it builds the index with
# `relaton index` (support#58, which replaced the Jekyll build) and forwards the
# optional per-flavor branding a data repo used to carry in its `_config.yml` —
# title, favicon and description (relaton#96 added the latter two CLI flags).
#
# The two "Build index" steps (gem source / git source) are the fragile part:
# they are near-duplicate command lines, so a flag added to one and forgotten in
# the other silently drops branding for every repo on the other source mode.
RSpec.describe ".github/workflows/data-deploy.yml" do
  repo_root = File.expand_path("..", __dir__)
  workflow = YAML.safe_load_file(File.join(repo_root, ".github/workflows/data-deploy.yml"))
  # Psych reads the unquoted `on:` key as YAML 1.1 boolean true.
  inputs = workflow.fetch(true).fetch("workflow_call").fetch("inputs")
  build_job = workflow.fetch("jobs").fetch("build_index_page")
  index_steps = build_job.fetch("steps").select { |s| s["run"]&.match?(/\brelaton index\b/) }
  # "Publish only from the repo's real default branch" — the one condition that
  # decides whether a run reaches actions/deploy-pages, reused by the
  # concurrency group below so the two cannot drift apart.
  deploy_gate = "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"

  it "keeps every input optional, so existing callers need no changes" do
    expect(inputs.values).to all(include("required" => false))
  end

  %w[favicon description].each do |input|
    describe "the #{input} input" do
      it "is declared, so callers can pass it" do
        # A reusable workflow rejects an undeclared input at parse time
        # ("Invalid input, 'favicon' is not defined in the referenced
        # workflow"), so a caller cannot work around a missing declaration.
        expect(inputs).to have_key(input)
      end

      it "is an optional string defaulting to the empty string" do
        # The empty default is load-bearing: it lets both build steps pass the
        # flag unconditionally. relaton's generator runs `presence(...)` on both
        # values, so `--favicon ""` is indistinguishable from not passing it.
        expect(inputs.fetch(input))
          .to include("required" => false, "default" => "", "type" => "string")
      end
    end
  end

  it "builds the index in both source modes" do
    expect(index_steps.map { |s| s["if"] })
      .to contain_exactly("inputs.source == 'gem'", "inputs.source == 'git'")
  end

  %w[favicon description].each do |input|
    it "hands #{input} to the shell through the environment, not `${{ }}`" do
      # GitHub substitutes `${{ }}` as raw text before bash parses the line, so
      # an inlined value is shell source: a description reading
      # `IEC "TC 1" registry` would word-split into stray argv entries, and one
      # containing $(...) would execute. Via env the runner passes it verbatim.
      index_steps.each do |step|
        expect(step.fetch("env")).to include(input.upcase => "${{ inputs.#{input} }}")
        expect(step.fetch("run")).not_to include("inputs.#{input}")
      end
    end
  end

  %w[--title --favicon --description --base-url].each do |flag|
    it "passes #{flag} in every build step" do
      # Both invocations must stay in sync — see the note at the top.
      expect(index_steps.map { |s| s.fetch("run") }).to all(include("#{flag} "))
    end
  end

  it "publishes only from the repository's real default branch" do
    # Hardcoding master/main once excluded the relaton-data-* repos that moved
    # their default branch to v2 — fresh data built, never published.
    expect(workflow.fetch("jobs").fetch("deploy").fetch("if")).to eq(deploy_gate)
  end

  describe "the concurrency group" do
    concurrency = workflow["concurrency"]

    it "is declared, so two Pages deployments cannot collide" do
      # Both runs reach actions/deploy-pages@v4 and the loser fails with a
      # concurrent-deployment error. Overlap is easy: the caller template fires
      # on `workflow_run` *and* a fallback cron, and a `source: git` build runs
      # for ~10 minutes. Declared here rather than per caller because GitHub
      # documents the *called* workflow's top level as where concurrency for a
      # reusable workflow belongs — `jobs.<id>.concurrency` on the calling job
      # "will not behave as expected".
      expect(concurrency).to be_a(Hash)
    end

    it "scopes the group to the calling repository" do
      # `github.repository` evaluates in the caller's context, so each
      # relaton-data-* repo queues against itself and never against a sibling.
      expect(concurrency.fetch("group")).to start_with("pages-${{ github.repository }}")
    end

    it "queues only the runs that can actually publish" do
      # Under GitHub's default `queue: single` a pending run is cancelled the
      # moment a third joins its group. Pull requests, tag pushes and pushes to
      # a non-default branch all build and then skip `deploy`, so parking them
      # in the deployment queue would let them drop a pending run carrying
      # freshly crawled data. Keying on the deploy job's *own* gate is what
      # keeps the split honest — assert they are literally the same expression,
      # so narrowing one and forgetting the other fails here.
      expect(concurrency.fetch("group")).to include(deploy_gate)
    end

    it "queues deployments instead of cancelling one mid-flight" do
      # Deliberate, and the opposite of GitHub's default: a cancelled
      # actions/deploy-pages run can leave the Pages deployment half-applied.
      expect(concurrency.fetch("cancel-in-progress")).to be(false)
    end
  end

  it "skips a build whose triggering workflow run failed" do
    # A `workflow_run` caller fires on `completed`, not `success`. The guard
    # lives here, not in each caller's `deploy:` job, so no caller can forget
    # it — a called workflow inherits the caller run's `github` context,
    # event payload included. `deploy` is `needs: build_index_page`, so
    # skipping the build skips the publish too.
    expect(build_job.fetch("if")).to eq(
      "github.event_name != 'workflow_run' || " \
      "github.event.workflow_run.conclusion == 'success'",
    )
  end
end
