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
end
