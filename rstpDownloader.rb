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

# Patch for ThreadPool
class ThreadPool
	def getNumberOfRunningTasks
		result = 0
		@threads.each do |aTaskExecutor|
			result += 1 if aTaskExecutor.isRunning()
		end
		return result
	end
end


class FileQuater < TaskAsync
	def initialize(configs, taskMan, period=3600)
		super("FileQuater")
		@configs = configs
		@taskMan = taskMan
		@period = period
	end

	def self.convertFmtToGrep(fmt)
		fmt = fmt.gsub("\-", "\\-")
		fmt = fmt.gsub("\.", "\\.")
		fmt = fmt.gsub("%Y", "[0-9]+")
		fmt = fmt.gsub("%y", "[0-9]+")
		fmt = fmt.gsub("%m", "[0-9]+")
		fmt = fmt.gsub("%d", "[0-9]+")
		fmt = fmt.gsub("%H", "[0-9]+")
		fmt = fmt.gsub("%M", "[0-9]+")
		fmt = fmt.gsub("%S", "[0-9]+")
		return fmt
	end

	DEF_POLLING_PERIOD = 5
	DEF_ERASE_MARGIN = 0.2

	def self.doQuater(path, filter, keep)
		path = File.expand_path(path)
		filter = convertFmtToGrep(filter)

		result = []
		FileUtil.iteratePath( path, filter, result, false, false, 1)
		result = result.sort{|a,b| b<=>a}

		n = 0
		result.each do |aResult|
			FileUtils.rm_f(aResult) if n >= keep
			sleep DEF_ERASE_MARGIN # This save the bandwidth of storage for actual download
			n = n + 1
		end
	end

	def execute
		sleep DEF_POLLING_PERIOD
		timingDo = @period / DEF_POLLING_PERIOD
		count = 0

		while( @taskMan.getNumberOfRunningTasks() > 1 ) do
			# assume the other rstp downloading task is running
			sleep DEF_POLLING_PERIOD
			count += 1
			if count % timingDo == 0 then
				# this is timing to do quater
				@configs.each do | key, aCamera |
					doQuater( aCamera["output"], aCamera["fileFormat"], aCamera["keep"].to_i )
					sleep DEF_POLLING_PERIOD
				end
			end
		end
		_doneTask()
	end
end

options = {
	:configFile => "config.json",
	:quaterPeriod => 3600
}

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: "

	opts.on("-c", "--config=", "Set config.json (default:#{options[:configFile]})") do |configFile|
		options[:configFile] = configFile.to_s
	end

	opts.on("-q", "--quaterPeriod=", "Set quarter period sec. (default:#{options[:quaterPeriod]})") do |quaterPeriod|
		options[:quaterPeriod] = quaterPeriod.to_i
	end
end.parse!


config = JsonUtil.loadJsonFile( options[:configFile], false, true)
taskMan = ThreadPool.new( config.length + 1)

config.each do | key, aCamera |
	taskMan.addTask( RstpDownloader.new( aCamera ) )
end
taskMan.addTask( FileQuater.new( config, taskMan, options[:quaterPeriod] ) )

taskMan.executeAll()
taskMan.finalize()

