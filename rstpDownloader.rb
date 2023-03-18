#!/usr/bin/env ruby

# Copyright 2023 hidenory
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fileutils'
require 'optparse'
require 'shellwords'
require 'json'
require_relative 'ExecUtil'
require_relative 'FileUtil'
require_relative 'TaskManager'


class JsonUtil
	def self.removeRemark(body)
		result = []
		body.each do | aLine |
			pos = aLine.index("# ")
			if pos then
				aLine = aLine.slice(0,pos)
			end
			result << aLine if !aLine.empty?
		end
		return result
	end

	def self.loadJsonFile(filePath, ensureJson=false, removeRemark=false)
		result = {}
		body = FileUtil.readFileAsArray(filePath)
		body = removeRemark(body) if removeRemark
		body = body.join("\n")
		body = StrUtil.ensureJson(body) if ensureJson
		begin
			result = JSON.parse(body)
		rescue => ex
		end
		return result
	end
end


class RstpDownloader < TaskAsync
	def initialize(config)
		super("RstpDownloader #{config}")
		@config = config
	end

	def buildExec()
		url = @config["url"].to_s
		pos = url.index("://")
		if pos && !@config["user"].empty? then
			pos2 = url.index("/", pos+3)
			url = "#{url.slice(0,pos+3)}#{@config["user"]}:#{@config["password"]}@#{url.slice(pos+3,url.length)}"
		end
		exec_cmd = "ffmpeg -i #{url} #{@config["options"]} -flags +global_header -f segment -segment_time #{@config["duration"]} -segment_format mp4 -reset_timestamps 1  -strftime 1 #{Shellwords.escape(@config["fileFormat"])}"
		exec_cmd += " 2>&1 > #{@config["log"]}" if !@config["log"].empty?
		return exec_cmd
	end

	def execute
		exec_cmd = buildExec()
		outputPath = @config["output"]
		FileUtil.ensureDirectory(outputPath)

		sleepDuration = @config["errorSleep"].to_i
		retryCount = @config["errorRetyCount"].to_i
		retryEnabled = @config["errorRetry"].to_s.downcase.strip == "enable"
		if !retryEnabled then
			retryCount = 1
			sleepDuration = 0
		end

		for i in 0..retryCount
			result = ExecUtil.execCmd(exec_cmd, outputPath)
			i = 0 if retryEnabled && result # If sucess, the retry count is clear
			sleep sleepDuration
		end
		_doneTask()
	end
end



options = {
	:verbose => false,
	:configFile => "config.json"
}

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: "

	opts.on("-c", "--config=", "Set config.json (default:#{options[:configFile]})") do |configFile|
		options[:configFile] = configFile.to_s
	end

	opts.on("", "--verbose", "Enable verbose status output") do
		options[:verbose] = true
	end
end.parse!


config = JsonUtil.loadJsonFile( options[:configFile], false, true)
taskMan = ThreadPool.new( config.length )

config.each do | key, aCamera |
	taskMan.addTask( RstpDownloader.new( aCamera ) )
end

taskMan.executeAll()
taskMan.finalize()

