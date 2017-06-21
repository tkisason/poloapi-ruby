#!/usr/bin/env ruby
# Kost

require 'bundler/setup'
require 'poloapi'
require 'logger'
require 'yaml'
require 'optparse'
require 'bigdecimal'

require 'pp'

# require 'pry'


$PRGNAME="lending"
$options = {}
$options['loglevel'] = 'WARN'
$options['logname'] = nil
$options['dryrun'] = false
$options['singleloop'] = false

# $options['maxordertime']=300
$options['maxordertime']=1500
$options['loanduration']=2
$options['loanautorenew']=0
$options['sleeploop']=60
$options['loanminamount'] = 0.01 # minimum amount to lend
# $options['loanmin'] = 0.0005 # global loan minimum rate
$options['loanmin'] = 0.0001 # global loan minimum rate
# $options['loanmincur']= {'BTC' => 0.0007500, 'ETH' => 0.0002 } # minimum rate per currency
$options['loanmincur']= {'BTC' => 0.0003000, 'ETH' => 0.0002 } # minimum rate per currency
$options['loanmaxorderamount'] = '1.32' # in front of which max order to put
$options['loanmaxorderamountcur'] = {'BTC' => 1.32, 'ETH' => 10.1 }
$options['loanmaxordersum'] = '3'
$options['loanmaxordersumcur'] = {'BTC' => 3.00, 'ETH' => 10.0 }

$options['loanorderdeduct'] = '0.000001' # how much to deduct from wall order (to execute order before order wall)

# helpful class for logger
class MultiDelegator
  def initialize(*targets)
    @targets = targets
  end

  def self.delegate(*methods)
    methods.each do |m|
      define_method(m) do |*args|
	@targets.map { |t| t.send(m, *args) }
      end
    end
    self
  end

  class <<self
    alias to new
  end
end

#begin
	optyaml = YAML::load_file(ENV['HOME']+'/.pololending')
# rescue # Errno::ENOENT
#end

if optyaml != nil then
	$options.merge!(optyaml)
end

# File.open(ENV['HOME']+'/.pololending-ex', 'w') {|f| f.write $options.to_yaml }

# initialize logger
if $options['logname'] != nil then
	log_file = File.open($options['logname'], 'a')
	$log = Logger.new MultiDelegator.delegate(:write, :close).to(STDERR, log_file)
else
	$log = Logger.new MultiDelegator.delegate(:write, :close).to(STDERR)
end
loglevel =  Logger.const_get $options['loglevel'] # Logger::INFO # default is ::WARN
$log.level = loglevel


OptionParser.new do |opts|
	opts.banner = "Usage: #{$PRGNAME} [options]"

	opts.on("-h", "--help", "Prints this help") do
		puts opts
		exit
	end

	opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
		$options['verbose'] = v
		$log.level = Logger::INFO
	end

	opts.on("-1", "--[no-]singleloop", "Perform single loop") do |v|
		$options['singleloop'] = v
	end

	opts.on("-r", "--[no-]report", "Report only in single loop") do |v|
		$options['report'] = v
		$options['singleloop'] = v
		$options['dryrun'] = v
		$log.level = Logger::INFO
	end

	opts.on("-d", "--[no-]debug", "Run in debug mode") do |v|
		$options['debug'] = v
		$log.level = Logger::DEBUG
	end

	opts.on("-s", "--secret NAME", "use NAME as secret to poloniex") do |optarg|
		$options['secret'] = optarg
	end

	opts.on("-k", "--key NAME", "use NAME as key to poloniex ") do |optarg|
		$options['key'] = optarg
	end

	opts.on("-l", "--log FILE", "log to FILE") do |optarg|
		$options['logname'] = optarg
	end

	opts.separator ""
	opts.separator "Example #1: #{$PRGNAME} -k poloniex-key -s poloniex-secret"
end.parse!

# pp $options

if !$options.has_key?('key') or !$options.has_key?('secret') then
	$log.error("No key/secrets specified! Specify with -k and -s!")
	exit
end

Poloapi.setup do | config |
    config.key = $options['key']
    config.secret = $options['secret']
end

def toggleAutoRenew(onr)
	result=JSON.parse(Poloapi.post('toggleAutoRenew', :orderNumber => onr))
	return result
end

def cancelOrder(oid)
	result=JSON.parse(Poloapi.post('cancelLoanOffer', :orderNumber => oid))
	return result
end

def getBestLoanOrder(curid)
	loanorders=JSON.parse(Poloapi.get('returnLoanOrders', :currency => curid))
	unless loanorders["offers"].nil?
		bestorder = loanorders["offers"].first 
		numloanoffers = loanorders["offers"].count
		$log.info("With #{numloanoffers} order(s), lowest order is: #{bestorder['rate']}")
		return bestorder['rate']
	end
	return nil
end

def getBestPossibleLoanOrder(curid)
	loanorders=JSON.parse(Poloapi.get('returnLoanOrders', :currency => curid))
	unless loanorders["offers"].nil?
		numloanoffers = loanorders["offers"].count
		exorder = loanorders["offers"].first 
		bestorder = loanorders["offers"].last
		sumamount = BigDecimal.new('0.0')
		maxsumamount = BigDecimal.new($options['loanmaxordersum'])
		loanorders["offers"].each_with_index do |offer,offid|
			sumamount=sumamount+BigDecimal.new(offer['amount'])
			if offer["amount"] > $options['loanmaxorderamount'] or (not $options['loanmaxordersum'].nil? and sumamount > maxsumamount) then
				bestorder = offer.dup
				# bestorder['rate'] = (bestorder['rate'].to_f - 0.00000001).to_s
				bestrate=(BigDecimal.new(bestorder['rate'])) - (BigDecimal.new($options['loanorderdeduct']))
				bestorder['rate'] = bestrate.to_s('F')
				$log.info("Looking best possible place, With #{numloanoffers} order(s), best possible order is (skipped #{offid}): #{bestorder['rate']}, higher is #{offer['rate']} with amount #{offer['amount']}")
				break
			else
				exorder=offer
			end
		end 
		return bestorder['rate']
	end
	return nil
end


def getMinLoanOrder(curid,options) 
	minorder=0.0 # sane minimum
	unless options['loanmin'].nil?
		minorder=options['loanmin']
	end
	unless options['loanmincur'][curid].nil?
		minorder=options['loanmincur'][curid]
	end
	return minorder
end

def mainLoop()
myofferloans=JSON.parse(Poloapi.post('returnOpenLoanOffers'))
unless myofferloans.nil?
	myofferloans.each do |cur,items|
		unless items.nil? then
			olamount=0.0
			olrate=0.0
			items.each do |item|
				olamount=olamount+item["amount"].to_f
				olrate=olrate+item["rate"].to_f
			end
			$log.info("Open orders for #{cur}: #{items.count} with #{olamount} average rate #{olrate/items.count}")
			bestorder=getBestLoanOrder(cur)
			items.each do |item|
				if bestorder.nil? then
					bestorder=item["rate"]
				end
				dt=DateTime.parse(item["date"])
				diff=Time.now.utc.to_i - dt.to_time.to_i
				if diff > $options['maxordertime'] then
					bOrder=getBestLoanOrder(cur)
					puts "#{bOrder} - #{item['rate']}"
					minorder=getMinLoanOrder(cur[0],$options)
					if bOrder.to_f >= item["rate"].to_f or item["rate"].to_f <= minorder then
						$log.info("Best order #{item['id']} with diff #{diff} - timeout reached, still best offer")
					else
						$log.warn("Canceling order #{item['id']} with time diff #{diff} - timeout reached")
						cancelOrder(item['id'])
					end
				end
			end
		end
	end
end

# Poloniex.balances

# if false
mybalances=JSON.parse(Poloapi.post('returnAvailableAccountBalances'))


unless mybalances.nil? or mybalances.empty?
	balstr = ''
	mybalances.each do |name,b|
		balstr << name
		balstr << ": "
		b.each do |cur|
			balstr << cur[0].to_s
			balstr << " "
			balstr << cur[1].to_s
			balstr << " "
		end
		balstr << "; "
	end
	$log.info "Available balance(s): #{balstr}"

	unless mybalances['lending'].nil? then
		balstr=''
		mybalances["lending"].each do |cur|
			balstr << cur[0]
			balstr << " "
			balstr << cur[1]
			balstr << " "
			$log.info "Available lending balance: #{balstr}"

			if cur[1].to_f < $options['loanminamount'] then
				$log.info "Minimum balance not reached for #{cur[0]}: #{$options['loanminamount']}"
				next	
			end

			bestorder=getBestPossibleLoanOrder(cur[0])
			# bestorder=getBestLoanOrder(cur[0])

			unless bestorder.nil?
				minorder=getMinLoanOrder(cur[0],$options)

				# create order with minimum loan defined
				bestorderf = bestorder.to_f
				loanorder=bestorder.to_f
				if bestorderf > minorder then
					orderstate="Above minimum."
				else
					orderstate="Minimum reached: #{minorder}."
					loanorder=minorder
				end
				if $options['dryrun'] then
					$log.warn("Dry run - #{orderstate} Not creating lend offer for #{cur[0]} #{cur[1]} with rate #{loanorder}")
				else
					$log.warn("#{orderstate} Creating lend offer for #{cur[0]} #{cur[1]} with rate #{loanorder}")
					loanorders=JSON.parse(Poloapi.post('createLoanOffer', {:currency => cur[0], :amount => cur[1], :duration => $options['loanduration'], :autoRenew => $options['loanautorenew'], :lendingRate => loanorder}))
					$log.info(loanorders.to_s)
				end
			end
		end
	else
		$log.info "No available lending balance"
	end
end

myactloans=JSON.parse(Poloapi.post('returnActiveLoans'))
unless myactloans["provided"].nil?
	#lendprofit=0.0
	lprofit=Hash.new
	lamount=Hash.new
	lcount=Hash.new
	lendcount=myactloans["provided"].count
	myactloans["provided"].each do |i|
		if lprofit[i["currency"]].nil?
			lprofit[i["currency"]]=BigDecimal.new(0)
		end
		if lamount[i["currency"]].nil?
			lamount[i["currency"]]=BigDecimal.new(0)
		end
		if lcount[i["currency"]].nil?
			lcount[i["currency"]]=1
		else
			lcount[i["currency"]]=lcount[i["currency"]]+1
		end
		lprofit[i["currency"]]=lprofit[i["currency"]]+BigDecimal.new(i["fees"])
		lamount[i["currency"]]=lamount[i["currency"]]+BigDecimal.new(i["amount"])
		# lendprofit=lendprofit+i["fees"].to_f 
	end
	profitstr=''
	lprofit.keys.each do |currency|
		total=lamount[currency]+lprofit[currency]
		profitstr << "#{currency} Orders: #{lcount[currency]}; #{lamount[currency].to_s('F')} with profit: #{lprofit[currency].to_s('F')} should be: #{total.to_s('F')} ; "
	end
	$log.info "With #{lendcount} loans active, #{profitstr}, "
end

unless myactloans["provided"].nil?
	myactloans["provided"].each do |i|
		if i["autoRenew"] == 1 then
			loanid=i["id"]
			$log.warn "Canceling auto renew on #{loanid}"
			ret=toggleAutoRenew(loanid)
			puts ret
			sleep 1
		end
	end
end

end # mainLoop()

if $options['singleloop'] then
	mainLoop()
else
	while true
		$log.info("Starting loop")
		begin
			mainLoop()
		rescue StandardError => e
			$log.warn("Error #{$!}: #{e.backtrace}")
		end
		$log.info("Finishing up and sleeping for #{$options['sleeploop']}")
		sleep $options['sleeploop']
	end
end
