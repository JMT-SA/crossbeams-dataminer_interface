# coding: utf-8

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'crossbeams/dataminer_interface/version'

Gem::Specification.new do |spec|
  spec.name          = 'crossbeams-dataminer_interface'
  spec.version       = Crossbeams::DataminerInterface::VERSION
  spec.authors       = ['James Silberbauer']
  spec.email         = ['jamessil@telkomsa.net']

  spec.summary       = 'Dataminer report building and extracting interface.'
  spec.description   = 'Dataminer report building and extracting interface.'
  spec.homepage      = 'https://github.com/JMT-SA'
  spec.license       = 'MIT'

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = 'TODO: Set to "http://mygemserver.com"'
  else
    raise 'RubyGems 2.0 or newer is required to protect against ' \
      'public gem pushes.'
  end

  spec.bindir        = 'exe'
  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'roda', '~> 2.25'
  spec.add_dependency 'tilt'
  spec.add_dependency 'crossbeams-dataminer'
  spec.add_dependency 'crossbeams-layout'
  spec.add_dependency 'axlsx'
  spec.add_dependency 'rouge'

  spec.add_development_dependency 'bundler', '~> 1.14'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'pry'
  spec.add_development_dependency 'yard'
  spec.add_development_dependency 'rubocop'
end
