#!/bin/bash

set -ev # (exit immediatly on failure and print script lines before execution)
# store current ruby
CURRENT_RUBY=`rvm current`
# set ruby to 2.5.3 (pre-installed on travis)
rvm 2.5.3
bundle update --jobs=3 --retry=3
bundle exec rake clean fetch
# restore previous ruby
rvm $CURRENT_RUBY
rm gemfiles/*.lock
bundle update --jobs=3 --retry=3
bundle exec rake compile

