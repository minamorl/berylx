# frozen_string_literal: true

require_relative 'lib/berylx/version'

Gem::Specification.new do |spec|
  spec.name = 'berylx'
  spec.version = Berylx::VERSION
  spec.summary = 'Graphable workflows over focused Ruby state'
  spec.description = 'A Ruby gem for composing named tasks into graphable workflows over focused state.'
  spec.authors = ['minamorl']
  spec.email = ['minamorl@users.noreply.github.com']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/minamorl/berylx'

  spec.required_ruby_version = '>= 3.2'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir[
    'lib/**/*.rb',
    'ext/berylx_native/*.{c,rb}',
    'README.md',
    'LICENSE',
    'AGENTS.md'
  ]
  spec.require_paths = ['lib']
  # native bridge (real 圏の C interpreter)。ビルドできない環境では
  # LoadError を握って pure Ruby interpreter へ自動フォールバックする。
  spec.extensions = ['ext/berylx_native/extconf.rb']

  # darkcore は berylx workflow の唯一の実行基盤 (EffectTree substrate)。必須依存。
  spec.add_dependency 'darkcore'
end
