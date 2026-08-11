# frozen_string_literal: true

require "securerandom"

# Encodes step outputs for GitHub Actions' `$GITHUB_OUTPUT` file.
#
# Only the heredoc form is used, never `name=value`. `name=value` terminates at
# the first newline, so any value that can contain one — and the branding this
# renders is free-form prose out of data-index/configs.yml — would spill its
# remaining lines into the file as further `key=value` assignments. That is an
# injection: a description containing a line `favicon=javascript:...` would
# define an unrelated step output.
#
# The heredoc closes that, but only while the delimiter is unguessable, hence a
# fresh random one per value rather than a fixed marker.
module GithubOutput
  # Long enough that a collision with a line of real prose is not a thing that
  # happens; the guard in .block covers the caller-supplied case anyway.
  DELIMITER_PREFIX = "ghadelim_"

  # Render a name => value hash as one string. Callers write it in a single
  # operation: a partial write would leave a dangling heredoc opener, which
  # corrupts the outputs of every *later* step in the job, not just this one.
  def self.render(pairs)
    pairs.map { |name, value| block(name, value) }.join
  end

  # One `name<<DELIM ... DELIM` block, newline-terminated.
  def self.block(name, value, delimiter: new_delimiter)
    body = normalize(value)

    # GitHub's parser fails the step when a *line* of the value is exactly the
    # delimiter; merely containing it is fine.
    if body.split("\n", -1).include?(delimiter)
      raise ArgumentError,
            "#{name}: value contains a line equal to the delimiter #{delimiter.inspect}"
    end

    "#{name}<<#{delimiter}\n#{body}\n#{delimiter}\n"
  end

  def self.new_delimiter
    "#{DELIMITER_PREFIX}#{SecureRandom.hex(16)}"
  end

  # A stray \r survives into the step's env var and then into the rendered
  # <meta name="description">.
  def self.normalize(value)
    value.to_s.gsub(/\r\n?/, "\n")
  end
  private_class_method :normalize
end
