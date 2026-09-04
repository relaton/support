# Guards the "orphan by omission" class that relaton/support#65 describes.
#
# `cimas cleanup-orphan-files` deletes a Cimas-written file the moment its path
# leaves a repo's `files:` mapping. So an un-mapping is a delete order, and the
# reason for it has to survive in the file that carries it. Prose does not: the
# `relaton-model-*` entries lost their model mapping in 31b3fda ("cimas: add new
# repos #45", 2024-10-12) with no note at all, and two of those repos still run
# the build those files drive.
#
# The convention this spec enforces:
#
#   # unmapped YYYY-MM-DD (org/repo#N): <reason>
#   #   <continuation lines, further indented>
#
# Inside a `files:` block every comment line must start or continue a marker,
# and every repo whose `files:` is empty must carry one. The rule needs no
# heuristic about which comments are about un-mapping, because inside that
# block there is nothing else to comment on.
require "cimas_config"

RSpec.describe "cimas.yml un-mapping markers" do
  cimas_path = CimasConfig::DEFAULT_CONFIG_PATH
  text = File.read(cimas_path)
  markers = CimasConfig.scan_unmapped(text)

  describe ".scan_unmapped" do
    it "reads a marker above a commented-out mapping" do
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-index:
            remote: ssh://git@github.com/relaton/relaton-index
            files:
              # unmapped 2026-09-03 (relaton/support#65): rake.yml is custom here.
              # .github/workflows/rake.yml: gh-actions/master/rake.yml
              .github/workflows/release.yml: gh-actions/master/release.yml
      YAML
      expect(found.map { |m| [m[:repo], m[:kind], m[:marked]] })
        .to eq([["relaton-index", :comment, true]])
    end

    it "reads a continuation line as part of the marker above it" do
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-data-itu:
            remote: ssh://git@github.com/relaton/relaton-data-itu
            files:
              # unmapped 2026-09-03 (relaton/support#65): crawler.yml is hand-owned.
              #   A sync would switch the daily cron back on.
              .github/workflows/deploy.yml: gh-actions/data/deploy.yml
      YAML
      expect(found.map { |m| m[:marked] }).to eq([true])
    end

    it "flags a comment inside files: that starts no marker" do
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-index:
            remote: ssh://git@github.com/relaton/relaton-index
            files:
              # .github/workflows/rake.yml: gh-actions/master/rake.yml custom
              .github/workflows/release.yml: gh-actions/master/release.yml
      YAML
      expect(found.map { |m| [m[:kind], m[:marked]] }).to eq([[:comment, false]])
    end

    it "flags an empty files: block with no marker" do
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-model-gb:
            remote: ssh://git@github.com/relaton/relaton-model-gb
            branch: main
            files:
          relaton-model-jis:
            remote: ssh://git@github.com/relaton/relaton-model-jis
            branch: main
            files:
      YAML
      expect(found.map { |m| [m[:repo], m[:kind], m[:marked]] }).to eq(
        [["relaton-model-gb", :empty, false], ["relaton-model-jis", :empty, false]],
      )
    end

    it "accepts an empty files: block whose marker sits under it" do
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-model-gb:
            remote: ssh://git@github.com/relaton/relaton-model-gb
            branch: main
            files:
              # unmapped 2026-09-03 (relaton/support#65): grammar only, no build.
      YAML
      expect(found.map { |m| [m[:kind], m[:marked]] }).to eq([[:empty, true]])
    end

    it "flags an inline empty files: mapping" do
      # Cimas reads `files: {}`, `files: []` and a bare `files:` the same way.
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-model-gb:
            remote: ssh://git@github.com/relaton/relaton-model-gb
            files: {}
          relaton-model-jis:
            remote: ssh://git@github.com/relaton/relaton-model-jis
            files: []
      YAML
      expect(found.map { |m| [m[:repo], m[:kind], m[:marked]] }).to eq(
        [["relaton-model-gb", :empty, false], ["relaton-model-jis", :empty, false]],
      )
    end

    it "flags a repo entry with no files: key at all" do
      # It maps nothing either, so every Cimas-written file in it is an orphan.
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-model-gb:
            remote: ssh://git@github.com/relaton/relaton-model-gb
            branch: main
      YAML
      expect(found.map { |m| [m[:repo], m[:kind], m[:marked]] })
        .to eq([["relaton-model-gb", :empty, false]])
    end

    it "stops at the groups: section" do
      # `  sites:` there has the shape of a repo entry, and a `files:` key
      # nested under a group would otherwise be read as a repo's mapping.
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          relaton-models:
            remote: ssh://git@github.com/relaton/relaton-models
            files:
              Gemfile: gh-actions/model/Gemfile
        groups:
          sites:
            - relaton.org
      YAML
      expect(found).to be_empty
    end

    it "ignores a comment outside a files: block" do
      found = CimasConfig.scan_unmapped(<<~YAML)
        repositories:
          # data
          relaton-data-iso:
            remote: ssh://git@github.com/relaton/relaton-data-iso
            # The repo's real default branch, renamed from master.
            branch: v2
            files:
              .github/workflows/deploy.yml: gh-actions/data/deploy.yml
      YAML
      expect(found).to be_empty
    end
  end

  it "records every commented-out mapping with a dated marker" do
    unmarked = markers.select { |m| m[:kind] == :comment && !m[:marked] }
    expect(unmarked).to be_empty,
                        "these comments inside a `files:` block start no " \
                        "`# unmapped YYYY-MM-DD (org/repo#N):` marker: " \
                        "#{unmarked.map { |m| "#{m[:repo]} line #{m[:line]}" }.join(', ')}"
  end

  it "records every empty files: block with a dated marker" do
    # An empty mapping is the widest delete order in the file: every
    # Cimas-written file in that repo becomes an orphan, not just one.
    unmarked = markers.select { |m| m[:kind] == :empty && !m[:marked] }
    expect(unmarked).to be_empty,
                        "these repos map no file and say why nowhere: " \
                        "#{unmarked.map { |m| m[:repo] }.join(', ')}"
  end

  it "dates every marker, and names the issue that decided it" do
    bad = markers.select { |m| m[:marked] }.reject do |marker|
      Date.strptime(marker[:date], "%Y-%m-%d")
      marker[:issue].match?(%r{\A[\w.-]+/[\w.-]+#\d+\z})
    rescue Date::Error
      false
    end
    expect(bad).to be_empty,
                   "these markers carry an unreadable date or issue: " \
                   "#{bad.map { |m| "#{m[:repo]} line #{m[:line]}" }.join(', ')}"
  end

  it "gives every repo entry a remote of its own" do
    # Not a marker rule, but the same failure: a shared remote makes Cimas
    # clone one repo into another's working directory and judge its tree
    # against the wrong mapping.
    config = CimasConfig.load
    duplicated = config.names.group_by { |name| config.slug(name) }
                       .select { |_, names| names.size > 1 }
    expect(duplicated).to be_empty,
                          "these entries share one remote: #{duplicated.inspect}"
  end
end
