# Extraction is the whole audit. A pin that is not extracted can never be
# reported, and the failure is silent: the run prints "0 deprecated found" and
# a reader takes that for clean.
#
# The reference implementation this port comes from (metanorma/ci#392,
# `.github/scripts/audit-actions.rb`) extracts line by line with
#
#   %r{^\s*uses:\s*([\w.-]+/[\w.-]+(?:/[\w.-]+)*)\s*@\s*(\S+)\s*$}
#
# and that regex is blind to two shapes this repo uses in most of its files.
# `^\s*uses:` makes no allowance for the YAML sequence dash, so a compact
# `- uses: actions/checkout@v4` step never matches; the trailing `\s*$` drops
# any pin that carries a comment after it. Run over this repo it sees 21 of the
# 35 pins, and the 14 it misses are every compact step pin.
#
# Walking the Psych AST instead of the lines is what removes both defects: a
# job-level `uses:` and a step-level `- uses:` are the same mapping pair, and a
# trailing comment is not part of the scalar. Each defect gets a named example
# below so neither can come back.
require "workflow_pins"

RSpec.describe WorkflowPins do
  let(:pins) { described_class.scan }

  def pins_in(file)
    pins.select { |pin| pin.file == file }
  end

  describe ".scan" do
    it "reads both scan paths" do
      scanned = pins.map { |pin| pin.file.split("/").first(2).join("/") }.uniq
      expect(scanned).to contain_exactly(".github/workflows", "cimas-config/gh-actions")
    end

    # The upstream regex's first blind spot. Every step in ci-spec.yml is
    # written this way, as are the steps in check-data.yml, crawler.yml and
    # make.yml.
    it "finds a pin written as a compact `- uses:` step" do
      expect(pins_in(".github/workflows/ci-spec.yml").map(&:to_s))
        .to include("actions/checkout@v4", "ruby/setup-ruby@v1")
    end

    # The upstream regex's second blind spot: `\s*$` cannot follow a comment.
    it "finds a pin that carries a trailing comment" do
      pin = pins_in(".github/workflows/data-deploy.yml")
            .find { |p| p.line == 250 }
      expect(pin).not_to be_nil,
                         "data-deploy.yml:250 is `- uses: actions/checkout@v4 " \
                         "# the data repo (has ./data)`; a pin with a comment " \
                         "after it must still be extracted"
      expect(pin.to_s).to eq("actions/checkout@v4")
    end

    it "finds a job-level reusable-workflow call" do
      expect(pins_in(".github/workflows/ci-lint.yml").map(&:to_s))
        .to eq(["metanorma/ci/.github/workflows/ci-lint.yml@main"])
    end

    it "finds the pins in the Cimas caller templates" do
      expect(pins_in("cimas-config/gh-actions/master/rake.yml").map(&:to_s))
        .to eq(["relaton/support/.github/workflows/rake.yml@main"])
    end

    it "reports a line number that points at the pin" do
      pins.each do |pin|
        line = File.readlines(pin.file)[pin.line - 1]
        expect(line).to include(pin.action),
                        "#{pin.file}:#{pin.line} does not hold #{pin.action}"
      end
    end

    it "splits the action from the ref" do
      pin = pins.find { |p| p.action == "metanorma/ci/gh-repo-status-action" }
      expect(pin.ref).to eq("main")
    end

    # The invariant the upstream regex broke, stated so that no future
    # extraction change can quietly narrow what the audit sees. The comparison
    # regex here is deliberately looser than any extractor: it only asks that a
    # line beginning with `uses:` or `- uses:` produced a pin.
    it "extracts every `uses:` line the tree holds" do
      loose = []
      described_class::SCAN_PATHS.each do |root|
        Dir.glob(File.join(root, "**", "*.{yml,yaml}")).sort.each do |file|
          File.readlines(file).each_with_index do |line, i|
            loose << [file, i + 1] if line.match?(/^\s*(-\s+)?uses:\s*\S+@/)
          end
        end
      end
      expect(pins.map { |p| [p.file, p.line] }.sort).to eq(loose.sort)
    end
  end

  # The skip rules need shapes this repo does not carry, so they are stated
  # against a fixture rather than against a workflow written to host them.
  describe ".from_yaml" do
    subject(:extracted) { described_class.from_yaml(source, file: "fixture.yml") }

    let(:source) { <<~YAML }
      jobs:
        build:
          uses: owner/repo/.github/workflows/x.yml@v1
          steps:
            - uses: owner/action@v2
            - uses: ./.github/actions/local
            - uses: docker://alpine:3.19
            - uses: owner/action@${{ matrix.ref }}
            - uses: owner/action
            - run: 'echo "uses: not/a-pin@v9"'
    YAML

    it "keeps the remote pins" do
      expect(extracted.map(&:to_s))
        .to eq(["owner/repo/.github/workflows/x.yml@v1", "owner/action@v2"])
    end

    it "skips a local action, a docker ref, an expression and an unpinned use" do
      expect(extracted.map(&:to_s)).not_to include(
        a_string_including("./"), a_string_including("docker://"),
        a_string_including("${{")
      )
    end

    # A `run:` script that happens to print the word is text, not a pin. The
    # line-based extractor upstream would be at risk here; the AST is not.
    it "does not mistake the body of a run: step for a pin" do
      expect(extracted.map(&:to_s)).not_to include("not/a-pin@v9")
    end
  end
end
