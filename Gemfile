source 'https://rubygems.org'

group :development, :test do
  gem 'minitest'
  gem 'minitest-reporters'
  gem 'minitest-debugger', :require => false
  gem 'rack-test'
  gem 'puma'
  if RUBY_VERSION < '1.9.3'
    # i18n 0.7.0 dropped support for Ruby 1.9.2 and older.  ActiveSupport
    # depends on i18n 0.7.0 since v 4.0.5.  For < 1.9.2 Ruby support, lock
    # down to these versions to maintain functionality.
    gem 'i18n', '< 0.7.0'
    gem 'activesupport', '< 4.0.5'
    gem 'appraisal'
  else
    gem 'appraisal'
  end
end

group :development do
  gem 'ruby-debug',   :platforms => [ :mri_18, :jruby ]
  gem 'debugger',     :platform  =>   :mri_19
  gem 'byebug',       :platforms => [ :mri_20, :mri_21, :mri_22 ]
#  gem 'perftools.rb', :platforms => [ :mri_20, :mri_21 ], :require => 'perftools'
  if RUBY_VERSION > '1.8.7'
    gem 'pry'
    gem 'pry-byebug', :platforms => [ :mri_20, :mri_21, :mri_22 ]
  else
    gem 'pry', '0.9.12.4'
  end
end

if defined?(JRUBY_VERSION)
  gem 'sinatra', :require => false
else
  gem 'sinatra'
end

if RUBY_VERSION >= '1.9.3'
  gem 'bson'
else
  gem 'bson', '1.10.2'
end

gemspec

