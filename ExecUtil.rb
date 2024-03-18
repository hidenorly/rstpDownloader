#  Copyright (C) 2022 hidenorly
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

require_relative "StrUtil"
require 'timeout'

class ExecUtil
	def self.execCmd(command, execPath=".", quiet=true)
		result = false
		if File.directory?(execPath) then
			exec_cmd = command
			exec_cmd += " > /dev/null 2>&1" if quiet && !exec_cmd.include?("> /dev/null")
			result = system(exec_cmd, :chdir=>execPath)
		end
		return result
	end

	def self.pid_exists?(pid)
		return processExists(pid)
	end

	def self.processExists?(pid)
		begin
			return Process::kill(0, pid) ? true : false
		rescue =>ex
		end
		return false
	end

	def self.killProcess(pid)
		result = false
		if pid then
			# try
			begin
				Process.detach(pid)
				Process.kill('TERM', -pid) # Kill process group
			rescue =>ex
				begin
					Process.kill('TERM', pid) if processExists?(pid) # Kill the pid
				rescue =>ex
				end
			end

			# Just in case
			exec_cmd = "kill -9 #{pid}"
			ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, ".", 1) if processExists?(pid)
			exec_cmd = "sudo kill -9 #{pid}"
			ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, ".", 1) if processExists?(pid)

			# check kill is success or not
			result = !processExists?(pid)
		end
		return result
	end

	def self.escape_arg(arg)
		arg = arg.to_s
		arg = arg.gsub(/(?=[^a-zA-Z0-9_.\/\-\x7f-\xff\n])/n, '\\')
		arg = arg.gsub("'", "'\\\\''")
		return "'#{arg}'"
	end

	def self.getArgsAndOptions(exec_cmd)
		## Replace /dev/null and 2>&1 with options
		exec_cmd = exec_cmd.gsub('>/dev/null 2>&1', '').gsub('> /dev/null 2>&1', '').gsub('>\\ /dev/null 2>&1', '')
		options = {}
		if exec_cmd.include?('>/dev/null')
			options[:out] = '/dev/null'
		end
		cmd_args = Shellwords.shellsplit(exec_cmd).map { |arg| escape_arg(arg) }
		return cmd_args, options
	end

	def self.spawn(command, execPath=".", runas=nil, quiet=true, verbose=false)
		result = nil
		if File.directory?(execPath) then
			exec_cmd = command
			exec_cmd += " > /dev/null 2>&1" if quiet && !exec_cmd.include?("> /dev/null")

			# convert to array to avoid sh execution (=avoid process group under sh)
#			cmd_array, options = getArgsAndOptions(exec_cmd)

			options = {:pgroup=>true, :chdir=>execPath}
			options[:uid] = options[:gid] = runas if runas

			## Replace /dev/null and 2>&1 with options
			if exec_cmd =~ /(\s+>+\s*)([^&\s]+)/
			  options[:out] = $2
			  exec_cmd.gsub!($1 + $2, '')
			end
			if exec_cmd =~ /(\s+2>&1)/
			  options[:err] = options[:out] || :err
			  exec_cmd.gsub!($1, '')
			end

			## Split command into array
			cmd_array = []
			exec_cmd.scan(/"(.*?)"|'(.*?)'|(\S+)/) do |match|
			  cmd_array << (match[0] || match[1] || match[2])
			end

			begin
				result = Process.spawn(*cmd_array, options)
			rescue => ex
				# retry without uid and gid
				options.delete(:uid) if options.has_key?(:uid)
				options.delete(:gid) if options.has_key?(:gid)
				result = Process.spawn(*cmd_array, options)
			end
			result = Process.getpgid(result) if result
		else
			puts "#{execPath} is invalid" if verbose
		end
		return result
	end

	def self.hasResult?(command, execPath=".", enableStderr=true)
		result = false

		if File.directory?(execPath) then
			exec_cmd = command
			exec_cmd += " 2>&1" if enableStderr && !exec_cmd.include?(" 2>")

			IO.popen(["bash", "-c", exec_cmd], "r", :chdir=>execPath) {|io|
				while !io.eof? do
					if io.readline then
						result = true
						break
					end
				end
				io.close()
			}
		end

		return result
	end

	def self.getExecResultEachLine(command, execPath=".", enableStderr=true, enableStrip=true, enableMultiLine=true)
		result = []

		if File.directory?(execPath) then
			exec_cmd = command
			exec_cmd += " 2>&1" if enableStderr && !exec_cmd.include?(" 2>")

			IO.popen(["bash", "-c", exec_cmd], "r", :chdir=>execPath) {|io|
				while !io.eof? do
					aLine = StrUtil.ensureUtf8(io.readline)
					aLine.strip! if enableStrip
					result << aLine
				end
				io.close()
			}
		end

		return result
	end

	def self.getExecResultEachLineWithTimeout(exec_cmd, execPath=".", timeOutSec=3600, enableStderr=true, enableStrip=true)
		result = []
		pio = nil
		begin
			Timeout.timeout(timeOutSec) do
				if File.directory?(execPath) then
					if enableStderr then
						pio = IO.popen(["bash", "-c", exec_cmd], STDERR=>[:child, STDOUT], :chdir=>execPath )
					else
						pio = IO.popen(["bash", "-c", exec_cmd], :chdir=>execPath )
					end
					if pio && !pio.eof?then
						aLine = StrUtil.ensureUtf8(pio.read)
						result = aLine.split("\n")
						if enableStrip then
							result.each do |aLine|
								aLine.strip!
							end
						end
					end
				end
			end
		rescue Timeout::Error => ex
#			puts "timeout error"
			if pio then
				if !pio.closed? && pio.pid then
					Process.detach(pio.pid)
					Process.kill(9, pio.pid)
				end
			end
		rescue
#			puts "Error on execution : #{exec_cmd}"
			# do nothing
		ensure
			pio.close if pio && !pio.closed?
			pio = nil
		end

		return result
	end

	def self.getExecResultEachLineWithInputs(command, execPath=".", inputs=[], enableStderr=true, enableStrip=true, enableMultiLine=true)
		result = []

		if File.directory?(execPath) then
			exec_cmd = command
			exec_cmd += " 2>&1" if enableStderr && !exec_cmd.include?(" 2>")

			IO.popen(["bash", "-c", exec_cmd], "r", :chdir=>execPath) {|io|
				inputs.each do |aLine|
					io.puts(aLine)
				end
				while !io.eof? do
					aLine = StrUtil.ensureUtf8(io.readline)
					aLine.strip! if enableStrip
					result << aLine
				end
				io.close()
			}
		end

		return result
	end
end
