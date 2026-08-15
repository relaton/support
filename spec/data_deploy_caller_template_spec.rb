# Guards the Cimas caller templates that Cimas syncs into every relaton-data-*
# repo: `.github/workflows/deploy.yml` and its pre-merge sibling
# `.github/workflows/check-index.yml`.
#
# The problem it encodes: a `push` trigger could never fire on crawled data.
# crawler.yml's "Push data" step commits with the default actions/checkout
# GITHUB_TOKEN, and GitHub deliberately raises no workflow events for
# GITHUB_TOKEN pushes. That left the daily cron as the only path from crawl to
# Pages — and it assumed a fixed one-hour gap that scheduled dispatch does not
# honour (11 of relaton-data-iana's last 12 Crawler runs *started* at or after
# 14:58 UTC despite a 14:00 cron, several past 16:00), so the 15:00 deploy
# usually indexed the previous day's data. Deploy and Crawler have since dropped
# `push` and `pull_request` entirely; what remains is asserted below.
#
# Dropping `pull_request` from Deploy also dropped the only pre-merge proof that
# the corpus still parses. That is back as its own caller — Check index, same
# reusable workflow, no Pages work — and the split between the two is what the
# `check-index.yml` block below pins.
#
# Ordering is now deterministic via `workflow_run`. The couplings below are all
# silent when broken — nothing goes red in CI, the fleet just quietly stops
# republishing — so they are pinned here.
RSpec.describe "cimas-config/gh-actions/data/*.yml (the Cimas caller templates)" do
  repo_root = File.expand_path("..", __dir__)
  template = ->(name) { YAML.safe_load_file(File.join(repo_root, "cimas-config/gh-actions/data", name)) }

  deploy = template.call("deploy.yml")
  crawler = template.call("crawler.yml")
  # Loaded lazily, unlike the two above: were check-index.yml ever missing, a
  # load here would die at describe-body evaluation with Errno::ENOENT and take
  # every unrelated example in the file with it.
  check_index_path = File.join(repo_root, "cimas-config/gh-actions/data/check-index.yml")
  # The authority on which repos this template is synced into, and on each one's
  # real default branch.
  cimas = YAML.safe_load_file(File.join(repo_root, "cimas-config/cimas.yml"))
  # Psych reads the unquoted `on:` key as YAML 1.1 boolean true.
  triggers = deploy.fetch(true)
  workflow_run = triggers["workflow_run"]
  deploy_job = deploy.fetch("jobs").fetch("deploy")

  # "0 14 * * *" -> 14
  cron_hour = ->(schedule) { Integer(schedule.fetch(0).fetch("cron").split.fetch(1)) }

  describe "the workflow_run trigger" do
    it "is declared, so a crawler commit reaches Pages the same day" do
      expect(workflow_run).to be_a(Hash)
    end

    it "names the crawler template's own `name:`" do
      # THE load-bearing assertion. `workflows:` matches the triggering
      # workflow's `name:` field, and both files are synced together by Cimas —
      # so renaming crawler.yml's `name:` silently stops the deploy trigger
      # firing in every data repo, with nothing red to notice.
      expect(workflow_run.fetch("workflows")).to eq([crawler.fetch("name")])
    end

    it "listens for completion rather than success" do
      # `success` is not a valid workflow_run activity type; the conclusion is
      # filtered centrally instead, by data-deploy.yml's build_index_page `if:`.
      expect(workflow_run.fetch("types")).to eq(["completed"])
    end

    it "accepts every default branch name in use across the fleet" do
      # `workflow_run`'s branch filter matches the *triggering* run's branch, so
      # this list has to cover every default branch the synced repos actually
      # use (23 of the 30 are on v2, six on main, one on master) for the file to
      # stay repo-agnostic. It is only a pre-filter: a repo carrying more than
      # one of those names lets a crawl on a dormant branch through, so
      # data-deploy.yml gates on `workflow_run.head_branch` being the repo's
      # real default branch, and publication on the run's own ref.
      #
      # Derived from cimas.yml rather than hardcoded, and compared against the
      # `push` trigger before that — this template has neither a `push` block
      # any more nor a list that is right by construction. A repo moving to a
      # fourth default branch would otherwise silently stop republishing: the
      # trigger just never fires there, with nothing red anywhere.
      repositories = cimas.fetch("repositories")
      defaults = cimas.fetch("groups").fetch("data").filter_map do |name|
        repositories.dig(name, "branch") if
          (repositories.dig(name, "files") || {}).key?(".github/workflows/deploy.yml")
      end

      expect(defaults).not_to be_empty
      expect(workflow_run.fetch("branches")).to include(*defaults.uniq)
    end
  end

  describe "what each template triggers on" do
    crawler_triggers = crawler.fetch(true)

    it "crawls only on a schedule or by hand" do
      # A `pull_request` crawl fetched an entire corpus and then threw it away:
      # crawler.yml's "Push data" step is gated `github.event_name !=
      # 'pull_request'`. On the largest flavors (ids at 166,658 documents, 3gpp
      # at 88,464) that is a very long run for nothing. `push` only re-ran what
      # the cron runs anyway, and `workflow_dispatch` covers wanting one sooner.
      #
      # The acknowledged cost: each data repo carries its own `crawler.rb`, and
      # the PR run was the only way to exercise a change to it without
      # committing — a dispatch run is not gated by that step and pushes its
      # crawled corpus to the branch it runs on.
      expect(crawler_triggers.keys).to contain_exactly("schedule", "workflow_dispatch")
    end

    it "deploys only from a finished crawl, the fallback cron, or by hand" do
      # A `pull_request` deploy ran the whole build — npm ci and the Vue compile
      # under `source: git`, then a full corpus parse and a Pages artifact
      # upload — and then skipped `deploy`, because publication is gated on the
      # repo's default branch. Minutes per PR for output nobody can see.
      #
      # `workflow_run` stays: it is not push-driven, and it is the only thing
      # that makes publication track the crawl rather than a cron guessed to
      # land after it (see the note at the top of this file).
      expect(triggers.keys).to contain_exactly("workflow_run", "schedule", "workflow_dispatch")
    end

    it "leaves no push or pull_request trigger in Deploy or Crawler" do
      # Stated separately from the two `contain_exactly` examples above because
      # this is the invariant that fails silently: re-adding either trigger just
      # burns Actions minutes fleet-wide, in 30 repos at once, with nothing red.
      #
      # Note what re-adding `pull_request` *here* would not be: a restored
      # pre-merge check. That lives in check-index.yml, which reaches the same
      # build through the same reusable workflow and stops short of Pages. On
      # Deploy the trigger only buys back the build-then-skip-the-publish path.
      [triggers, crawler_triggers].each do |t|
        expect(t).not_to have_key("push")
        expect(t).not_to have_key("pull_request")
      end
    end

    it "splits publishing and pre-merge checking across two callers" do
      # The whole shape in one example: exactly one of the three templates
      # triggers on a pull request, and it is not the one that can publish.
      # Collapsing them back into a single caller is what this forbids —
      # whichever direction it is collapsed in.
      on_pull_request = {
        "deploy.yml" => triggers,
        "crawler.yml" => crawler_triggers,
        "check-index.yml" => YAML.safe_load_file(check_index_path).fetch(true),
      }.select { |_, t| t.key?("pull_request") }.keys

      expect(on_pull_request).to eq(["check-index.yml"])
    end
  end

  it "schedules its fallback cron clear of the crawler's observed window" do
    # A fallback for days the crawler commits nothing, not the primary path.
    # The old "one hour after the crawl" gap was inside the drift, so require a
    # real margin over the crawler template's own cron.
    expect(cron_hour.call(triggers.fetch("schedule")))
      .to be >= cron_hour.call(crawler.fetch(true).fetch("schedule")) + 3
  end

  describe "the pre-merge check caller (check-index.yml)" do
    # Everything here loads inside the example, so a missing template fails as
    # one red example rather than aborting the file.
    doc = -> { YAML.safe_load_file(check_index_path) }
    job = -> { doc.call.fetch("jobs").values.fetch(0) }

    it "exists as its own Cimas template" do
      # support#62 dropped `pull_request` from Deploy for good reasons and took
      # the fleet's only pre-merge validation with it: `relaton index` parses the
      # whole corpus, so one malformed data/<flavor>-*.yaml fails the build for
      # the entire flavor. Merged green, that surfaces hours later as a red
      # *scheduled* Deploy on the default branch — never on the PR that caused
      # it — while Pages keeps serving the previous deployment, so there is
      # nothing user-visible to notice either.
      expect(File.exist?(check_index_path)).to be(true),
                                               "the pre-merge check caller is missing; without it a PR " \
                                               "touching data/ runs no build at all in 30 repos"
    end

    it "triggers on pull requests and nothing else" do
      # `workflow_dispatch` is the edit to resist, and the reason it is pinned
      # rather than merely omitted: dispatching THIS workflow from the default
      # branch satisfies the shared workflow's publish gate exactly as Deploy
      # does, so a workflow named "Check index" would configure Pages, upload
      # the artifact and publish for real. Dispatch Deploy for that.
      expect(doc.call.fetch(true).keys).to contain_exactly("pull_request")
    end

    it "calls the same shared workflow Deploy does" do
      # Equality with deploy.yml rather than a literal string: two callers, one
      # build definition. Pointed at anything else, a PR would be checked
      # against a build that has drifted from the one that publishes — green
      # here and broken on merge, which is the failure this file exists to stop.
      expect(job.call.fetch("uses")).to eq(deploy_job.fetch("uses"))
    end

    it "passes no inputs and declares no guard of its own" do
      # Same doctrine as deploy.yml, and the reason there is no `validate-only`
      # input: an input has to arrive in a `with:` block, which no synced caller
      # may carry (spec/cimas_data_pages_spec.rb forbids a literal there, and a
      # hand-added one is reverted by the next sync with nothing red). What
      # makes this a validation run is decided centrally instead — the shared
      # workflow gates both Pages steps and the `deploy` job on the run's ref,
      # and a pull_request run's ref is refs/pull/N/merge.
      expect(job.call).not_to have_key("with")
      expect(job.call).not_to have_key("if")
      expect(job.call).not_to have_key("concurrency")
      expect(doc.call).not_to have_key("concurrency")
    end

    it "is named distinctly from the templates synced alongside it" do
      # `name:` is an identity GitHub keys on: deploy.yml's `workflow_run`
      # selects the triggering workflow by name, so a collision here would make
      # a Check index run fire Deploy. It is also what a required status check
      # would be named after.
      names = [deploy.fetch("name"), crawler.fetch("name"), doc.call.fetch("name")]

      expect(doc.call.fetch("name")).to eq("Check index")
      expect(names.uniq.size).to eq(3)
    end
  end

  describe "what it deliberately leaves to the shared workflow" do
    it "calls the shared data-deploy.yml" do
      expect(deploy_job.fetch("uses")).to eq("relaton/support/.github/workflows/data-deploy.yml@main")
    end

    it "declares no concurrency of its own" do
      # data-deploy.yml owns it (see spec/data_deploy_workflow_spec.rb). A
      # duplicate group here would only add a second queue in front of the same
      # deployment, and per GitHub's docs a caller-side group that collides with
      # the called workflow's can cancel the caller.
      expect(deploy).not_to have_key("concurrency")
      expect(deploy_job).not_to have_key("concurrency")
    end

    it "carries no failed-crawler `if:` guard" do
      # Also central, so a repo whose deploy.yml drifts still gets it.
      expect(deploy_job).not_to have_key("if")
    end

    it "passes no inputs at all" do
      # THE reason branding moved into data-index/configs.yml. cimas.yml maps
      # this file into 30 repos as a whole-file copy, so anything in a `with:`
      # here is either wrong for the other 29 or — once a repo hand-edits it —
      # silently reverted by the next `cimas sync`. Branding failed silently (the
      # page just loses its favicon), which is why it moved to configs.yml.
      #
      # `source: git` used to be the one deliberate exception, because losing it
      # failed loudly with `Could not find command "index"`. It no longer needs
      # to be anywhere: `source` defaults to `git` in the shared workflow, so the
      # twelve callers still carrying the pin can lose it to a sync harmlessly.
      expect(deploy_job).not_to have_key("with")
    end
  end
end
