# ■step0. 基本設定
# ------------------------------------------------------------------------------------------
$adb_path    = "●ここをadbのパスに書き換えてください●"   # ←通常は C:\Users\ユーザ名\AppData\Roaming\SideQuest\platform-tools\adb.exe です。
$backup_path = ".\data"

if (-not (Test-Path $adb_path)) {
   Write-Host "つかいかた.txt を読んでadb.exeパスの設定を行ってください。"
   exit
}




# ■step1. 差分ダウンロード
# ------------------------------------------------------------------------------------------

# adbでカスタムソングのデータを未ダウンロード分のみダウンロードし、
# songid_to_dir.txtにSongIDとフォルダ名の対応を追記

$adb = $adb_path
$remote_path = "/sdcard/BMBFData/CustomSongs"
$local_path = "$backup_path\BMBFData\CustomSongs"
$songid_to_dir_path = "$backup_path\songid_to_dir.txt"

function Run-Main() {
	$remote_songs = & $adb shell ls "$remote_path"
	$local_songs = Get-ChildItem -name -attr dir "$local_path"

	$download_songs = $remote_songs | ?{ -not ($local_songs -contains $_.Trim()) }

	$cnt = 0
	$download_songs |
	%{
		$cnt++
		Write-Progress "-- SONG DOWNLOAD --" "$cnt / $($download_songs.count)" -PercentComplete ($cnt / $download_songs.count * 100)
		$local_song_path = $local_path + "\" + $_.Trim() # 最後スペースのフォルダはwindowsで扱えない
		& $adb pull "$remote_path/$_" "$local_song_path" > $null

		# songid_to_dir.txt の追記
		@{ SongID=Get-SongID("$local_song_path\info.dat"); Dir=[system.io.path]::GetFileName($local_song_path) } |
		%{ New-Object PSObject -Property $_ } |
		select SongID, Dir |
		ConvertTo-Csv -NoTypeInformation | select -skip 1 |
		Add-Content -Encoding UTF8 $songid_to_dir_path
	}

	# 世代バックアップ
	cp $songid_to_dir_path "$songid_to_dir_path.$(Get-Date -Format yyyyMMdd)"
	ls "$songid_to_dir_path.*" | sort CreationTime -desc | select -skip 5 | rm
}

function Get-SongID($info_file_path) {
	$info_text = [System.IO.File]::ReadAllText($info_file_path)

	$info_json = $info_text | ConvertFrom-Json
	$mapFiles = $info_json._difficultyBeatmapSets | % {
		$_._difficultyBeatmaps | % {
			$_._beatmapFilename
		}
	}

	$info_file_dir = (Get-Item $info_file_path).Directory.FullName
	$hash_base_str = ""
	$hash_base_str += $info_text
	$mapFiles | %{
		$hash_base_str += [System.IO.File]::ReadAllText($info_file_dir + "\" + $_)
	}

	$bytes = [System.Text.Encoding]::UTF8.GetBytes($hash_base_str)
	$sha1 = new-object System.Security.Cryptography.SHA1CryptoServiceProvider
	$song_hash = ($sha1.ComputeHash($bytes) | % { $_.ToString("x2") }) -join ""

	return "custom_level_" + $song_hash
}

Run-Main




# ■step2. song_list.txt 更新
# ------------------------------------------------------------------------------------------

# config.jsonから、song_list.txtへプレイリストとid、タイトルの対応を追記・更新する。
# config.jsonに存在しない曲の情報も消さずに保持し続けることで、BMBFから消した曲もどのプレイリストにあるかを持ち続ける。
# idとフォルダ名対応は「song_list.json作成」で情報追加する

$adb = $adb_path
$remote_json_path = "/sdcard/BMBFData/config.json"
$local_json_path = "$backup_path\BMBFData\config.json"
$song_list_path = "$backup_path\song_list.txt"
$local_path = "$backup_path\BMBFData\CustomSongs"

function Run-Main() {
	# config.jsonダウンロード　●不要ならコメントアウト
	& $adb pull "$remote_json_path" "$local_json_path"

	# config.json から新しいリストを読み込み
	$json_str = Get-Content -Encoding UTF8 $local_json_path
	$json_str = $json_str -replace ",`"Mods`".*","" # 余計な文字が入っていてそのままではjsonとして読めないので修正
	$json_str = $json_str + "}"
	$song_list_new = $json_str | ConvertFrom-Json | Convert-SongList

	# song_list.txt からリストを読み込み
	$song_list = Get-Content -Encoding UTF8 $song_list_path | Select-String -NotMatch "^#" | ConvertFrom-Csv

	# song_list_new の曲を削除
	$song_list = $song_list | ?{ -not ($song_list_new.id -contains $_.id) }
	if($song_list -isnot [array]) { $song_list = @($song_list) }

	# 新しい曲追加
	$song_list = $song_list + $song_list_new
	$song_list = $song_list | sort playlist, title

	# 書き出し：表示用
	$song_list_diap = ""
	$song_list |  Group-Object playlist |
	%{
		$song_list_diap += "# ###### $($_.Name) ######`n"
		$_.group |
		%{
			$song_list_diap += "# $($_.title)`n"
		}
		$song_list_diap += "# `n# `n# `n"
	}
	$song_list_diap | Set-Content -Encoding UTF8 $song_list_path

	# 書き出し：CSV形式
	$song_list | Select-Object playlist, title, id | ConvertTo-Csv | Add-Content -Encoding UTF8 $song_list_path

	# 世代バックアップ
	cp $song_list_path "$song_list_path.$(Get-Date -Format yyyyMMdd)"
	ls "$song_list_path.*" | sort CreationTime -desc | select -skip 5 | rm
}

function Convert-SongList {
	Param( [Parameter(ValueFromPipeline=$true)] $json )
	
	$list = @()
	
	$json.Playlists |
	%{
		$playlist = $_.PlaylistName -replace "`n|`r",""
		$_.SongList |
		%{
			$list += @{
				playlist    = $playlist;
				title       = $_.SongName;
				id          = $_.SongID;
			}
		}
	}
	
	$list = $list | %{New-Object psobject -Property $_}
	
	return $list
}

Run-Main




# ■step3. song_list.json作成
# ------------------------------------------------------------------------------------------

# song_list.html で利用するデータ(song_list.json)を、
# song_list.txt, songid_to_dir.txt, 実フォルダinfo.datから生成する
# PlayerData.datからスコア追記

$adb = $adb_path
$remote_player_data = "/sdcard/Android/data/com.beatgames.beatsaber/files/PlayerData.dat"
$local_player_data = "$backup_path\BMBFData\PlayerData.dat"
$local_path = "$backup_path\BMBFData\CustomSongs"
$song_list_path = "$backup_path\song_list.txt"
$songid_to_dir_path = "$backup_path\songid_to_dir.txt"
$song_list_json = "$backup_path\song_list.json"

$old_json = Get-Content -Encoding UTF8 $song_list_json | Select-Object -Skip 1 | ConvertFrom-Json
$old_json_hash = @{}
$old_json | % { $old_json_hash[$_.id] = $_ }

$song_to_dir = Get-Content $songid_to_dir_path | ConvertFrom-Csv

$song_list = Get-Content -Encoding UTF8 $song_list_path |
             Select-String -NotMatch "^#" | ConvertFrom-Csv

# song_listの各曲のinfo.dat情報を収集
$song_list | Add-Member dir ""
$song_list | Add-Member add_info null
$song_list |
% {
  $songID = $_.id.Trim()
  $_.id = $songID
  
  # Find from $old_json
  # このブロックをコメントアウトすれば、info.datファイルのみから生成する動作になる
  $hit = $old_json_hash[$songID]
  if ($hit -ne $null) {
    $_.dir = $hit.dir
    $_.add_info = $hit.add_info
    return # continue
  }
  
  # Find from info.dat
  $hit = $song_to_dir | ? { $_.SongID -eq $_.Dir } | ? { $_.SongID -eq $songID }
  if ($hit -eq $null) {
    $hit = $song_to_dir | ? { $_.SongID -eq $songID }
  }
  
  if ($hit -ne $null) {
    $_.dir = $hit[0].Dir
    $info_path = "$local_path\$($_.dir)\info.dat"
    $_.add_info = Get-Content -Encoding UTF8 $info_path | ConvertFrom-Json
  }
}

# song_listの各曲のスコアを収集
& $adb pull "$remote_player_data" "$local_player_data"

$player_data = Get-Content -Encoding UTF8 $local_player_data | ConvertFrom-Json
$player_data_hash = @{}
$player_data.localPlayers[0].levelsStatsData | % { if ($_.highScore -gt 0) { $player_data_hash[$_.levelId] = $_ } }

$song_list | Add-Member score 0
$song_list | Add-Member playCount 0
$song_list | Add-Member maxRank ""
$song_list |
% {
  $songID = $_.id.Trim()
  
  $hit = $player_data_hash[$songID]
  if ($hit -ne $null) {
    $_.score = $hit.highScore
    $_.playCount = $hit.playCount
    $_.maxRank = @("","D","C","B","A","S","SS")[$hit.maxRank]
  }
}

# 書き出し
$song_list = $song_list | ?{ $_.dir -ne "" }

"let song_list = " | Set-Content -Encoding UTF8 $song_list_json
$song_list | ConvertTo-Json | Add-Content -Encoding UTF8 $song_list_json




# ■step4. song_list_quest.json作成
# ------------------------------------------------------------------------------------------

# config.jsonからQuest実機側の曲一覧を作ってsong_list_quest.jsonに出力

$local_json_path = "$backup_path\BMBFData\config.json"
$song_list_json = "$backup_path\song_list.json"
$song_list_quest_json = "$backup_path\song_list.quest.json"

# config.json から新しいリストを読み込み
$json_str = Get-Content -Encoding UTF8 $local_json_path
$json_str = $json_str -replace ",`"Mods`".*","" # 余計な文字が入っていてそのままではjsonとして読めないので修正
$json_str = $json_str + "}"
$config_list = $json_str | ConvertFrom-Json | Convert-SongList

# song_list.jsonの読み込み
$song_list_json_data = Get-Content -Encoding UTF8 $song_list_json | select -skip 1 | ConvertFrom-Json
$song_list_json_hash = @{}
$song_list_json_data | % { $song_list_json_hash[$_.id] = $_ }

$song_list_quest = @()
$config_list | 
% {
  $songID = $_.id.Trim()
  
  $hit = $song_list_json_hash[$songID]
  if ($hit -ne $null) {
    $hit.playlist = $_.playlist # playlistはquest側のものを上書き
    $song_list_quest += $hit
  }
}

# 書き出し
$song_list_quest = $song_list_quest | ?{ $_.dir -ne "" }

"let song_list_quest = " | Set-Content -Encoding UTF8 $song_list_quest_json
$song_list_quest | ConvertTo-Json | Add-Content -Encoding UTF8 $song_list_quest_json




