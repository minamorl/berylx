# frozen_string_literal: true

module Berylx
  class Task
    def self.[](name, &block)
      new(name, &block)
    end

    def self.build(name, &block)
      self[name, &block]
    end

    attr_reader :name

    def initialize(name, &block)
      raise ArgumentError, 'Task requires a block' unless block

      @name = name.to_sym
      @block = block
    end

    # body は focus を返しても Effect を返してもよい
    # (spec: berylx.task.body.return in [focus, effect])。
    # Effect が返ったときは **呼び出した圏の handler マップ** で畳む
    # (spec: berylx.task.body.effect.category = same_handler_map)。
    # 畳み方を Task 自身が決め打ちにすると、body に入った途端に圏が変わり、
    # 「handler で選べるのは Task の粒度まで」という穴が塞がらない。
    def call(focus, &fold)
      root = Result.coerce_focus(focus)
      result = Result.normalize(fold_body(@block.call(root), fold))
      result.is_a?(Err) ? with_task_context(result) : result
    rescue StandardError => e
      Result.err(root || focus, e.class.name.to_sym, e.message, cause: e, failed_node: @name, trace: [@name])
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def |(other)
      self >> other
    end

    def rescue_with(handler = nil, name = nil, &block)
      Sequence.build_rescue(self, handler, name, &block)
    end

    def compile
      Graph.from(self)
    end

    def nodes
      [self]
    end

    private

    # fold が渡らない呼び出し (Root | Task の直接実行、C interpreter からの
    # 委譲) は定義により real 圏なので real の handler マップで畳む。
    #
    # 畳みは意図的に上の rescue の内側に置く。Task の body が投げた例外は
    # 従来から結果封筒 Err になる (result.no_implicit_raise) ので、body が
    # 返した Effect を解釈する途中の例外 (未知タグの KeyError など) だけを
    # 別扱いにする理由が無い。この一貫性でよいかは spec の
    # open_question task_body.unknown_tag が人間ゲートに預けている。
    def fold_body(produced, fold)
      return produced unless produced.is_a?(Darkcore::Effect)

      folder = fold || ->(effect) { EffectTree.fold_body(effect, EffectTree.real_handlers) }
      folder.call(produced)
    end

    def with_task_context(result)
      error = result.error.failed_node ? result.error : result.error.prepend_trace(@name)
      Err.new(result.focus, error)
    end
  end
end
