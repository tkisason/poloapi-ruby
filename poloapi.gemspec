# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'poloapi/version'

Gem::Specification.new do |spec|
  spec.name          = "poloapi"
  spec.version       = Poloapi::VERSION
  spec.authors       = ["Vlatko Kosturjak"]
  spec.email         = ["vlatko.kosturjak@gmail.com"]
  spec.homepage	     = 'https://github.com/kost/poloapi-ruby'
  spec.description   = %q{Provides a wrapper for poloniex.com api. It allows to programmaticaly trade cryptocurrencies.}
  spec.summary       = %q{Provides a wrapper for poloniex.com api}
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"

  spec.add_dependency 'rest-client'
  spec.add_dependency 'addressable'

end
