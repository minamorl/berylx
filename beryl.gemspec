# frozen_string_literal: true

require_relative 'lib/beryl/version'

Gem::Specification.new do |spec|
  spec.name = 'beryl'
  spec.version = Beryl::VERSION
  spec.summary = 'Graphable workflows over focused Ruby state'
  spec.description = 'A Ruby gem for composing named tasks into graphable workflows over focused state.'
  spec.authors = ['minamorl']
  spec.email = ['minamorl@users.noreply.github.com']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/minamorl/beryl'

  spec.required_ruby_version = '>= 3.2'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir[
    'lib/**/*.rb',
    'README.md',
    'LICENSE',
    'AGENTS.md'
  ]
  spec.require_paths = ['lib']

  # darkcore は beryl workflow の唯一の実行基盤 (EffectTree substrate)。必須依存。
  spec.add_dependency 'darkcore'
end
