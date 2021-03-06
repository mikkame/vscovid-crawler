#!/bin/bash
source .env
channels_name=vscovid19
ts=`date '+%s'`

# チームのチャンネルID取得
# 一日に一回でいい
get_channels_id() {
	channels_list_file="tmp/channels_list.json"
	channels_list_ts=0
	if [ -e $channels_list_file ]; then
		channels_list_ts=`date '+%s' -r $channels_list_file`
	fi
	# ファイルのタイムスタンプが一日経過しているか
	channels_list_diff=$((ts - channels_list_ts))
	if [ $channels_list_diff -gt 86400 ]; then
		echo get channels list
		# 全チャンネルの一覧を取得
		channels_list=`wget -q -O - --post-data "token=${slack_token}&exclude_archived=true" https://slack.com/api/channels.list`
		# ファイルにキャッシュ
		echo $channels_list > $channels_list_file
	else
		# キャッシュを復元
		channels_list=`cat $channels_list_file`
	fi
	# channels_listをchannels_nameで絞り込んでchannels_idを得る
	channels_id=`echo $channels_list | jq '.channels[] | select(.name == "'${channels_name}'")' | jq .id`
	channels_id=${channels_id:1:-1}
	echo $channels_id
	return 0
}

# チャンネルのメンバー取得
# 十分間に一回でいい
get_members_list() {
	channels_id=$1
	members_list_file="tmp/members_list.json"
	members_list_ts=0
	if [ -e $members_list_file ]; then
		members_list_ts=`date '+%s' -r $members_list_file`
	fi
	# ファイルのタイムスタンプが十分間経過しているか
	members_list_diff=$((ts - members_list_ts))
	if [ $members_list_diff -gt 600 ]; then
		echo get channels info
		# channels_idのチャンネルの詳細情報を取得
		channels_info=`wget -q -O - --post-data "token=${slack_token}&channel=${channels_id}" https://slack.com/api/channels.info`
		# channels_infoからメンバー一覧を取り出す
		members_list=`echo $channels_info | jq .channel.members[]`
		# ファイルにキャッシュ
		echo $members_list > $members_list_file
	else
		# キャッシュから復元
		members_list=`cat $members_list_file`
	fi
	echo $members_list
	return 0
}

# URLから自治体名を得る
get_govname_by_url() {
	url=$1
	domain=`echo $url | cut -d'/' -f 3`
	govname=`grep $domain --include="*.csv" ./data/*|cut -d',' -f 1|cut -d':' -f 2`
}

send_message() {
	member_id=$1
	# vscovid-crawler:offered-members にいない人にだけDMを送る
	already_offered=`redis-cli SISMEMBER vscovid-crawler:offered-members ${member_id}`
	if [ $already_offered = "1" ]; then
		continue
	fi
	echo offer to $member_id
	# vscovid-crawler:queue-* を一件GET
	key=`redis-cli KEYS vscovid-crawler:queue-* | tail -n 1`
	# URLを得る
	url=`redis-cli GET ${key}`
	echo $url
	# URLからmd5を得る
	md5=`echo $url | md5sum | cut -d' ' -f 1`
	# URLが404でないことを確認
	url_not_found=`wget --spider $url 2>&1 |grep -c '404 Not Found'`
	echo url_not_found $url_not_found
	# 404だった場合
	if [ $url_not_found = "1" ]; then
		# vscovid-crawler:queue-{URLのMD5ハッシュ} をDEL
		redis-cli DEL "vscovid-crawler:queue-$md5"
		continue
	fi
	govname=`get_govname_by_url ${url}`
	echo $govname
	# unixtime
	timestamp=`date '+%s'`
	# vscovid-crawler:offered-members をSADD
	redis-cli SADD "vscovid-crawler:offered-members" $member_id
	# vscovid-crawler:queue-{URLのMD5ハッシュ} をDEL
	redis-cli DEL "vscovid-crawler:queue-$md5"
	# vscovid-crawler:job-{URLのMD5ハッシュ} をSET
	redis-cli SET "vscovid-crawler:job-$md5" "${url},${member_id},${timestamp}"
	# Slack DM送信
	im_open=`wget -q -O - --post-data "token=${slack_token}&user=${member_id}" https://slack.com/api/im.open`
	im_id=`echo $im_open | jq .channel.id`
	im_id=${im_id:1:-1}
	json=`eval "echo \"$(cat url-map-message.json)\""`

	wget -q -O - --post-data "$json" \
	--header="Content-type: application/json" \
	--header="Authorization: Bearer ${slack_token}" \
	https://slack.com/api/chat.postMessage
	echo ""
}

channels_id=`get_channels_id`
members_list=`get_members_list $channels_id`

echo members num ${#members_list[@]}

# 一秒に一回でいい
# 各メンバーにDMを送る
# テスターのID
#members_list="xUUL8QC8BUx xU011H85CM0Wx xUUQ99JY5Rx xU011C3YGDABx"
for member in $members_list; do
	member_id=${member:1:-1}
	$(send_message member_id)
done
