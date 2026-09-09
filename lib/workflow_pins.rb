# frozen_string_literal: true

require "psych"

# Every GitHub Actions pin — `uses: <owner>/<action>@<ref>` — that the workflow
# YAML in this repo holds. One command and two specs consume it:
#
#   bin/actions-audit           -> the quarterly sweep and the report
#   spec/deprecated_actions_spec.rb -> the pull-request gate
#   spec/workflow_pins_spec.rb  -> the extraction itself
#
# Extraction walks the Psych AST, not the lines of the file. The reference
# implementation this port comes from (metanorma/ci#392) matches
#
#   %r{^\s*uses:\s*([\w.-]+/[\w.-]+(?:/[\w.-]+)*)\s*@\s*(\S+)\s*$}
#
# against each line, and that misses two shapes this repo uses constantly:
# `^\s*uses:` cannot see the YAML sequence dash of a compact
# `- uses: actions/checkout@v4` step, and the trailing `\s*$` cannot see a pin
# with a comment after it. Over this repo it reads 21 of 35 pins and calls the
# rest clean.
#
# The AST has neither problem. A job-level `uses:` and a step-level `- uses:`
# are the same mapping pair, a comment is not part of a scalar, and the word
# `uses:` inside a `run:` script or a comment is not a mapping pair at all.
# Psych also gives each node a `start_line`, so the report can name the line
# without a second pass. And because the AST holds raw scalars, the YAML 1.1
# boolean that turns the `on:` key into `true` — the quirk
# spec/data_deploy_workflow_spec.rb works around with `fetch(true)` — never
# arises here.
#
# What this does not cover: an action reached through an expression
# (`@${{ matrix.ref }}`), a local action (`./.github/actions/...`) and a Docker
# reference are all skipped. None names an upstream version that can rot.
class WorkflowPins
  Error = Class.new(StandardError)

  REPO_ROOT = File.expand_path("..", __dir__).freeze

  # The workflows this repo runs, and the caller templates Cimas copies into
  # the fleet. `gh-actions/model/` also holds a Makefile and a Gemfile, which
  # the glob leaves alone.
  SCAN_PATHS = [".github/workflows", "cimas-config/gh-actions"].freeze

  # A ref that names no upstream release. Nothing here can be deprecated or
  # deleted out from under the workflow, so nothing here is worth reporting.
  SKIP_PREFIXES = ["./", "../", "docker://"].freeze

  Pin = Struct.new(:file, :line, :action, :ref, keyword_init: true) do
    def to_s
      "#{action}@#{ref}"
    end
  end

  # Every pin under `paths`, in file order. `file` is relative to `root`, so a
  # report can print it and a reader can open it.
  def self.scan(root: REPO_ROOT, paths: SCAN_PATHS)
    paths.flat_map do |dir|
      Dir.glob(File.join(dir, "**", "*.{yml,yaml}"), base: root).sort
         .flat_map do |rel|
        from_yaml(File.read(File.join(root, rel), encoding: "UTF-8"), file: rel)
      end
    end
  end

  def self.from_yaml(source, file:)
    pins = []
    Psych.parse_stream(source, filename: file) do |document|
      collect(document, file, pins)
    end
    pins
  rescue Psych::SyntaxError => e
    # A file this cannot read is not a file with no pins. Saying so is the one
    # answer an audit must never give quietly.
    # Psych's message already names the file it was given.
    raise Error, e.message
  end

  def self.collect(node, file, pins)
    if node.is_a?(Psych::Nodes::Mapping)
      node.children.each_slice(2) do |key, value|
        next unless key.is_a?(Psych::Nodes::Scalar) && key.value == "uses"
        next unless value.is_a?(Psych::Nodes::Scalar)

        pin = build(value.value, file, value.start_line + 1)
        pins << pin if pin
      end
    end

    # A Scalar has no children, so the pair handled above is not counted twice.
    # An Alias has none either, so a pin reached only through a YAML anchor
    # (`- uses: *pin`) would be dropped. GitHub Actions rejects anchors in a
    # workflow file, so no file in scope can hold one.
    node.children&.each { |child| collect(child, file, pins) }
  end
  private_class_method :collect

  def self.build(value, file, line)
    text = value.to_s.strip
    return nil if text.empty?
    return nil if SKIP_PREFIXES.any? { |prefix| text.start_with?(prefix) }
    return nil if text.include?("${{")

    action, at, ref = text.rpartition("@")
    return nil if at.empty? || action.empty? || ref.empty?

    Pin.new(file: file, line: line, action: action, ref: ref)
  end
  private_class_method :build
end
