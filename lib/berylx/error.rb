# frozen_string_literal: true

module Berylx
  class Error < StandardError
    attr_reader :code, :cause, :failed_node, :trace, :parallel_errors, :metadata

    def self.[](code, message = code.to_s, **context)
      new(code, message, **context)
    end

    def self.from(value, **context)
      return value.with_context(**context) if value.is_a?(self)

      cause = context[:cause] || (value if value.is_a?(::Exception))
      code = context[:code] || code_from(cause)
      message = context[:message] || message_from(cause, code)

      new(code, message, **context, cause: cause)
    end

    def self.code_from(cause)
      cause ? cause.class.name.to_sym : :error
    end

    def self.message_from(cause, code)
      cause ? cause.message : code.to_s
    end

    def initialize(code, message = code.to_s, **context)
      super(message)
      @code = code.to_sym
      @cause = context[:cause]
      @failed_node = context[:failed_node]&.to_sym
      @trace = normalize_trace(context.fetch(:trace, []))
      @parallel_errors = context.fetch(:parallel_errors, []).freeze
      @metadata = context.fetch(:metadata, {}).freeze
      @fatal = context.fetch(:fatal, false)
      set_backtrace(@cause.backtrace) if @cause&.backtrace
    end

    def fatal?
      @fatal
    end

    def with_context(**context)
      self.class.new(
        @code,
        message,
        cause: context.fetch(:cause, @cause),
        failed_node: context[:failed_node] || @failed_node,
        trace: context[:trace] ? normalize_trace(context[:trace]) : @trace,
        parallel_errors: context[:parallel_errors] || @parallel_errors,
        metadata: context[:metadata] ? @metadata.merge(context[:metadata]) : @metadata,
        fatal: context.fetch(:fatal, @fatal)
      )
    end

    def prepend_trace(node)
      node_name = node.respond_to?(:name) ? node.name : node
      with_context(failed_node: @failed_node || node_name, trace: [node_name, *@trace])
    end

    def unwrap
      return self unless @cause

      @cause
    end

    def to_exception
      unwrap
    end

    def to_h
      {
        code: @code,
        message: message,
        failed_node: @failed_node,
        trace: @trace,
        fatal: fatal?,
        parallel_errors: @parallel_errors.map { _1.respond_to?(:to_h) ? _1.to_h : _1 },
        metadata: @metadata
      }
    end

    private

    def normalize_trace(trace)
      Array(trace).compact.map { _1.respond_to?(:name) ? _1.name.to_sym : _1.to_sym }.freeze
    end
  end
end
