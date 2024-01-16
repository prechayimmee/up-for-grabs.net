# frozen_string_literal: true

require 'up_for_grabs_tooling'
require 'open3'

root = Pathname.new(Dir.pwd)

result = CommandLineValidator.validate(root)

CommandLineFormatter.output(result)

exit(1) unless result[:success]
