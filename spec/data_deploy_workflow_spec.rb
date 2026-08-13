# Guards the reusable Pages workflow's caller contract: it builds the index with
# `relaton index` (support#58, which replaced the Jekyll build) and resolves the
# per-flavor branding a data repo used to carry in its `_config.yml` — title,
# favicon and description (relaton#96 added the latter two CLI flags) — from
# relaton/support's data-index/configs.yml rather than from a caller `with:`
# block, which `cimas sync` overwrites without trace.
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
  steps = build_job.fetch("steps")
  # Anchored to the command, not to a bare mention: the resolve step's `run` and
  # comments must never be able to join this set, or the flag assertions below
  # would be checked against a step that has no business carrying them.
  index_steps = steps.select { |s| s["run"]&.match?(/^\s*(bundle exec )?relaton index /) }
  step_index = ->(step) { steps.index(step) or raise "step not found" }
  root_checkout = steps.find { |s| s["uses"]&.start_with?("actions/checkout") && s["with"].nil? }
  support_checkout = steps.find { |s| s["name"].to_s.include?("relaton/support") }
  branding_step = steps.find { |s| s["id"] == "branding" }
  # "Publish only from the repo's real default branch" — the one condition that
  # decides whether a run reaches actions/deploy-pages, reused by the
  # concurrency group below so the two cannot drift apart.
  deploy_gate = "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"

  it "keeps every input optional, so existing callers need no changes" do
    expect(inputs.values).to all(include("required" => false))
  end

  %w[title favicon description support-ref].each do |input|
    describe "the #{input} input" do
      it "is declared, so callers can pass it" do
        # A reusable workflow rejects an undeclared input at parse time
        # ("Invalid input, 'favicon' is not defined in the referenced
        # workflow"), so a caller cannot work around a missing declaration.
        expect(inputs).to have_key(input)
      end

      it "is an optional string defaulting to the empty string" do
        # The empty default is load-bearing in both directions: the resolve step
        # passes every flag unconditionally and reads blank as "caller set
        # nothing, use configs.yml", and relaton's generator runs `presence(...)`
        # so `--favicon ""` is indistinguishable from not passing it.
        expect(inputs.fetch(input))
          .to include("required" => false, "default" => "", "type" => "string")
      end
    end
  end

  describe "the removed mode input" do
    # `relaton index` used to take `--mode embedded|dom|static-json`, trading the
    # crawler-indexable DOM against page weight. relaton-cli now always emits
    # sharded JSON (`search-NNNN.json` + `detail-NNNN.json` behind a ~110 KB
    # index.html) and the flag is gone, so there is nothing left to choose.
    it "declares no mode input" do
      # Not merely unused: a caller passing an input the called workflow does not
      # declare fails the run with "Invalid input, 'mode' is not defined in the
      # referenced workflow", so this and the callers have to move together. No
      # relaton-data-* caller passes one today.
      expect(inputs).not_to have_key("mode")
    end

    it "passes no --mode to relaton index" do
      # Why a leftover flag is worse than an ordinary error: Thor's legacy
      # default prints a usage error and exits 0, so the build step goes GREEN
      # having written no _site at all, and the run then dies at
      # actions/upload-pages-artifact with `tar: _site/: Cannot open: No such
      # file or directory` — red, but pointing at the wrong step entirely.
      # (relaton-data-ids shows exactly that shape today for a different reason:
      # its gem-source build has no `index` command at all.) The upstream change
      # adds `Command.exit_on_failure?` so it will exit 1 where the fault is —
      # not merged yet, and no reason to leave the flag here either way.
      index_steps.each { |step| expect(step.fetch("run")).not_to include("--mode") }
    end

    it "keeps no MODE in the build environment" do
      index_steps.each { |step| expect(step.fetch("env").keys).not_to include("MODE") }
    end
  end

  it "builds the index in both source modes" do
    expect(index_steps.map { |s| s["if"] })
      .to contain_exactly("inputs.source == 'gem'", "inputs.source == 'git'")
  end

  %w[title favicon description].each do |input|
    it "hands #{input} to the shell through the environment, not `${{ }}`" do
      # GitHub substitutes `${{ }}` as raw text before bash parses the line, so
      # an inlined value is shell source: a description reading
      # `IEC "TC 1" registry` would word-split into stray argv entries, and one
      # containing $(...) would execute. Via env the runner passes it verbatim.
      # `title` is in this set too: it now originates in relaton/support's
      # configs.yml rather than in the calling repo's own deploy.yml.
      index_steps.each do |step|
        expect(step.fetch("env"))
          .to include(input.upcase => "${{ steps.branding.outputs.#{input} }}")
        expect(step.fetch("run")).not_to include("steps.branding")
      end
    end

    it "builds the index from the resolved #{input}, never straight from the input" do
      # The inputs are overrides that pass THROUGH the resolver, which applies
      # the configs.yml fallback. Reading inputs.<x> directly here would restore
      # the old behaviour where an unset input meant "no branding".
      index_steps.each { |step| expect(step.to_s).not_to include("inputs.#{input}") }
    end
  end

  describe "resolving branding from relaton/support" do
    it "checks out relaton/support, the branding source of truth" do
      # Branding cannot live in the caller: cimas.yml maps
      # .github/workflows/deploy.yml as a whole-file copy for 29 repos, so a
      # `with:` block is wiped on the next sync and the page silently loses its
      # favicon and description.
      expect(support_checkout).not_to be_nil
      expect(support_checkout.fetch("uses")).to start_with("actions/checkout@")
      expect(support_checkout.fetch("with").fetch("path")).to eq(".relaton-support")
    end

    it "resolves the support repo from the `job` context, not the `github` one" do
      # A called workflow inherits the CALLER's `github` context, so
      # `github.repository` is the data repo — that would check the data repo out
      # over itself. `job.workflow_repository` is the repo this file came from.
      with = support_checkout.fetch("with")
      expect(with.fetch("repository")).to eq("${{ job.workflow_repository }}")
      expect(with.fetch("repository")).not_to include("github.")
    end

    it "reads branding from the commit this workflow was itself loaded from" do
      # `job.workflow_sha` is the reusable workflow file's own commit, so
      # resolver code and configs.yml can never come from different commits, and
      # `@some-branch` tests that branch's branding for free.
      #
      # Asserted against the `job` context specifically because the plausible
      # wrong spellings both fail silently rather than loudly: `github.*` names
      # the caller's workflow, and `github.job_workflow_sha` is an OIDC claim
      # rather than a context property, so it evaluates to null and `ref:` falls
      # back to support's default branch with the build still green.
      ref = support_checkout.fetch("with").fetch("ref")
      expect(ref).to eq("${{ inputs.support-ref || job.workflow_sha }}")
      expect(ref).not_to include("github.")
    end

    it "checks out support only after the data repo" do
      # A checkout into the workspace root clears the directory first, which
      # would delete a subdirectory checked out before it.
      expect(step_index.call(support_checkout)).to be > step_index.call(root_checkout)
    end

    it "fetches only the paths the resolver needs, in cone mode" do
      # Cone mode (the default) is correct for directory paths; setting
      # sparse-checkout-cone-mode: false would silently reinterpret these as
      # file globs and fetch nothing.
      with = support_checkout.fetch("with")
      expect(with.fetch("sparse-checkout").split).to contain_exactly("bin", "lib", "data-index")
      expect(with).not_to have_key("sparse-checkout-cone-mode")
    end

    it "leaves no credential behind in the workspace" do
      expect(support_checkout.fetch("with").fetch("persist-credentials")).to be(false)
    end

    it "resolves branding before the expensive source-specific build" do
      # The git-source build exports BUNDLE_GEMFILE to $GITHUB_ENV for every
      # later step, and a broken configs.yml should not cost a ~10-minute
      # frontend compile before it surfaces.
      expect(branding_step).not_to be_nil
      index_steps.each do |step|
        expect(step_index.call(branding_step)).to be < step_index.call(step)
      end
    end

    it "runs the resolver out of the support checkout" do
      # Ordering matters twice over: the script does not exist until the support
      # checkout has run, and the checkout must itself follow the root one.
      expect(branding_step.fetch("run")).to include(".relaton-support/bin/index-branding")
      expect(step_index.call(branding_step)).to be > step_index.call(support_checkout)
    end

    it "appends to $GITHUB_OUTPUT and interpolates nothing into its shell" do
      # Same reason as the build steps: the caller's inputs reach the script as
      # env vars, not as text substituted into the command line.
      run = branding_step.fetch("run")
      expect(run).to include(">> \"$GITHUB_OUTPUT\"")
      expect(run).not_to include("${{")
      expect(branding_step.fetch("env").keys).to contain_exactly("TITLE", "FAVICON", "DESCRIPTION")
    end

    it "forwards each caller input to its own resolver flag" do
      # Without this, `--title "$FAVICON"` would satisfy a bare "passes --title"
      # assertion while silently swapping two of the three values.
      run = branding_step.fetch("run")
      { "title" => "TITLE", "favicon" => "FAVICON", "description" => "DESCRIPTION" }
        .each { |flag, var| expect(run).to include(%(--#{flag} "$#{var}")) }
    end

    it "no longer derives a title in the shell" do
      # The retired `Derive title` step upcased the repo slug, giving
      # "RFCS Index"; configs.yml's `display` is authoritative now.
      expect(steps.to_s).not_to include("steps.meta")
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
