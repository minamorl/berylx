# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'minitest', '~> 5.0'
gem 'rake', '~> 13.0'
gem 'rubocop', '~> 1.64', require: false
gem 'rubocop-minitest', '~> 0.35', require: false

# darkcore effect substrate — beryl workflow の載せ替え先 (移行期はテストのみ)。
# 未公開 gem のため sibling repo への path 依存。core (require 'beryl') は
# 依存せず、require 'beryl/effect_tree' したときだけ読み込む。
gem 'darkcore', path: '../darkcore-ruby'
