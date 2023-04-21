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
		if !body.empty? then
			body = removeRemark(body) if removeRemark
			body = body.join("\n")
			body = StrUtil.ensureJson(body) if ensureJson
			begin
				result = JSON.parse(body)
			rescue => ex
			end
		end
		return result
	end
end


class CronUtil
	def self.parse(cronLine)
		result= nil
		fields = cronLine.to_s.strip.split(/\s+/)
		if fields.length == 5 then
			minute = parseField(fields[0], 0, 59)
			hour = parseField(fields[1], 0, 23)
			dom = parseField(fields[2], 1, 31)
			month = parseField(fields[3], 1, 12)
			dow = parseField(fields[4], 0, 6)

			result = {
				:minute => minute,
				:hour => hour,
				:dayOfMonth => dom,
				:month => month,
				:dayOfWeek => dow
			}
		else
			puts "Invalid cron format: expect m h dom mon dow" if cronLine
		end
		return result
	end

	def self.parseField(field, minVal, maxVal)
		result = nil
		if field=="*" then
			result = (minVal..maxVal).to_a
		elsif field.include?("/") then
			parts = field.split("/")
			startVal = (parts[0] != "*") ? parseRange(parts[0], minVal, maxVal) : minVal
			result = (startVal..maxVal).step(parts[1].to_i).to_a
		else
			result = parseRange(field, minVal, maxVal)
		end
		return result
	end

	def self.parseRange(field, minVal, maxVal)
		startVal = minVal
		endVal = maxVal

		if field.include?("-") then
			parts = field.split("-")
			startVal = parts[0].to_i
			endVal = parts[1].to_i
		else
			startVal = endVal = field.to_i
		end

		if startVal < minVal || endVal > maxVal then
			puts ("Invalid value: #{field}. expect the range between #{minVal} and #{maxVal}")
		end

		return (startVal..endVal).to_a
	end

	def self.isTriggered(cronFields)
		now = Time.now()

		return cronFields[:minute].include?(now.min) &&
			cronFields[:hour].include?(now.hour) &&
			cronFields[:dayOfMonth].include?(now.day) &&
			cronFields[:month].include?(now.month) &&
			cronFields[:dayOfWeek].include?(now.wday)
	end
end


class ShutdownTaskToRestart < TaskAsync
	def initialize(cronFields)
		super("ShutdownTaskToRestart #{cronFields}")
		@cronFields = cronFields
	end

	def execute
		while( @running ) do
			sleep 1
			exit() if CronUtil.isTriggered(@cronFields)
		end
		_doneTask()
	end
end

class ConfigUtil
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

	def self.getFileRelatedFromConfig(configs)
		results = []
		configs.each do | key, aCamera |
			results << {:output=>aCamera["output"], :fileFormat=>aCamera["fileFormat"], :keep=>aCamera["keep"].to_i}
		end
		return results
	end

	def self.getOutputPathsFromConfig(configs)
		results = []
		configs.each do | key, aCamera |
			results << aCamera["output"]
		end
		return results
	end
end



class DirectoryWatcher < TaskAsync
	def initialize(targetDirs, timeOut=300, stopByTimeOut=true)
		super("DirectoryWatcher")
		@timeOut = timeOut
		@files = {}
		targetDirs.each do |aTargetDir|
			@files[aTargetDir]=[]
		end
		@enable = true
		@stopByTimeOut = stopByTimeOut
	end

	def checkNewFilesAddedFromLast(path)
		files = Dir.entries(path)
		delta = files - @files[path]
		result = !delta.empty?
		@files[path] = files
		return result
	end

	def cancel
		@enable = false
	end

	def onTimeOut(path)
		puts "Timeout:#{path}!!!"
	end

	def execute
		i = 1
		while( @enable ) do
			# assume the other rstp downloading task is running
			sleep 1
			if i % @timeOut == 0 then
				foundTimeOut = false
				@files.each do | path, files |
					if !checkNewFilesAddedFromLast(path) then
						# Found not new files are added. Maybe the download task is not working.
						onTimeOut(path)
						foundTimeOut = true
					end
					sleep 1 # This save the bandwidth of storage for actual download
				end
				break if @stopByTimeOut && foundTimeOut
			end
			i = i + 1
		end
		_doneTask()
	end
end

class ProcessKillByDirectoryWatcher< DirectoryWatcher
	attr_accessor :pid

	def initialize(targetDir, pid, timeOut=300, enableExitIfFail=false, verbose=false)
		super([targetDir], timeOut, true)
		@pid = pid
		@enableExitIfFail = enableExitIfFail
		@verbose = verbose
	end

	def onTimeOut(path)
		puts "Timeout:pid=#{@pid}:path=#{path}" if @verbose
		killProces(@pid)
		exit() if @enableExitIfFail && ExecUtil.processExists?(@pid)
		@pid = nil
	end
end


class RtspDownloader < TaskAsync
	def initialize(config, verbose)
		super("RtspDownloader #{config}")
		@config = config
		@verbose = verbose
	end

	def buildExec()
		url = @config["url"].to_s
		pos = url.index("://")
		if pos && !@config["user"].empty? then
			pos2 = url.index("/", pos+3)
			url = "#{url.slice(0,pos+3)}#{@config["user"]}:#{@config["password"]}@#{url.slice(pos+3,url.length)}"
		end
		exec_cmd = "ffmpeg"
		exec_cmd += " -loglevel quiet" if !@verbose
		exec_cmd += " -i #{url} #{@config["options"]} -flags +global_header -f segment -segment_time #{@config["duration"]} -segment_format mp4 -reset_timestamps 1  -strftime 1 #{@config["fileFormat"]}"
		exec_cmd += " > #{!@config["log"].to_s.empty? ? @config["log"] : "/dev/null"} 2>&1"
		return exec_cmd
	end

	def execute
		exec_cmd = buildExec()
		outputPath = @config["output"]
		FileUtil.ensureDirectory(outputPath)

		# ensure retry related values
		sleepDuration = @config["errorSleep"].to_i
		retryCount = @config["errorRetyCount"].to_i
		retryEnabled = @config["errorRetry"].to_s.downcase.strip == "enable"
		if !retryEnabled then
			retryCount = 1
			sleepDuration = 0
		end
		runas = nil
		runas = @config["runas"] if @config.has_key?("runas")

		# setup new file checker

		# do download with retry
		pid = nil
		for i in 0..retryCount
			pid = ExecUtil.spawn(exec_cmd, outputPath, runas, true, @verbose)
			status = nil
			puts "Start:#{pid}:#{exec_cmd}" if @verbose

			if pid then
				@watcher = ThreadPool.new(1)
				watcherTask = ProcessKillByDirectoryWatcher.new( outputPath, pid, (@config["duration"].to_f*1.5), retryEnabled, @verbose )
				@watcher.addTask( watcherTask ) if retryEnabled
				@watcher.executeAll()

				begin
					pid, status = Process.wait2(pid)
				rescue => ex
					puts "#{pid}:#{status}:#{exec_cmd}: the process wait caused exception" if @verbose
				end

				watcherTask.cancel()
				@watcher.terminate()
				@watcher.finalize()
			end

			if retryEnabled then
				i = 0 if status && (status.success? || status.signaled?) # If success or process killer, the retry count is clear
				sleep sleepDuration
				puts "Retry:#{i}:#{status}:#{exec_cmd}" if @verbose
			end
		end
		puts "End:pid=\"#{pid}\":#{exec_cmd}" if @verbose

		# finalize watcher
		@watcher = nil

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
	DEF_POLLING_PERIOD = 5
	DEF_ERASE_MARGIN = 0.2

	def initialize(configs, taskMan, period=3600, verbose)
		super("FileQuater")
		@configs = ConfigUtil.getFileRelatedFromConfig(configs)
		@taskMan = taskMan
		@period = (period > DEF_POLLING_PERIOD) ? period : DEF_POLLING_PERIOD
		@verbose = verbose
	end

	def doQuater(path, filter, keep)
		path = File.expand_path(path)
		filter = ConfigUtil.convertFmtToGrep(filter)

		result = []
		FileUtil.iteratePath( path, filter, result, false, false, 1)
		result = result.sort{|a,b| b<=>a}

		n = 0
		result.each do |aResult|
			if n >= keep then
				puts "FileQuater:remove #{aResult}" if @verbose
				FileUtils.rm_f(aResult)
				sleep DEF_ERASE_MARGIN # This save the bandwidth of storage for actual download
			end
			n = n + 1
		end
	end

	def execute
		sleep DEF_POLLING_PERIOD
		timingDo = @period / DEF_POLLING_PERIOD
		count = 0

		while( @taskMan.getNumberOfRunningTasks() > 0 ) do
			# assume the other rtsp downloading task is running
			sleep DEF_POLLING_PERIOD
			count += 1
			if count % timingDo == 0 then
				# this is timing to do quater
				@configs.each do | aCamera |
					doQuater( aCamera[:output], aCamera[:fileFormat], aCamera[:keep] )
					sleep DEF_POLLING_PERIOD
				end
			end
		end
		_doneTask()
	end
end

options = {
	:configFile => "config.json",
	:quaterPeriod => 3600,
	:restartTime => nil,
	:verbose => false
}

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: "

	opts.on("-c", "--config=", "Set config.json (default:#{options[:configFile]})") do |configFile|
		options[:configFile] = configFile.to_s
	end

	opts.on("-q", "--quaterPeriod=", "Set quarter period sec. (default:#{options[:quaterPeriod]})") do |quaterPeriod|
		options[:quaterPeriod] = quaterPeriod.to_i
	end

	opts.on("-r", "--restartTime=", "Set restart time (crontab style:m h dom mon dow) e.g.:\"0 5 * * *\" (default:#{options[:restartTime]})") do |restartTime|
		options[:restartTime] = restartTime
	end

	opts.on("-v", "--verbose", "Set verbose") do
		options[:verbose] = true
	end
end.parse!

config = JsonUtil.loadJsonFile( options[:configFile], false, true)

if config.empty? then
	puts "Please have config file. \"#{options[:configFile]}\""
else
	taskMan = ThreadPool.new( config.length )
	config.each do | key, aCamera |
		taskMan.addTask( RtspDownloader.new( aCamera, options[:verbose] ) )
	end

	taskManManager = ThreadPool.new()
	cronFields = CronUtil.parse( options[:restartTime] )
	taskManManager.addTask( ShutdownTaskToRestart.new( cronFields ) ) if cronFields!=nil
	taskManManager.addTask( FileQuater.new( config, taskMan, options[:quaterPeriod], options[:verbose] ) )

	taskManManager.executeAll()
	taskMan.executeAll()
	taskMan.finalize()
	puts "End:downloader tasks" if options[:verbose]

	taskManManager.terminate()
	taskManManager.finalize()
end