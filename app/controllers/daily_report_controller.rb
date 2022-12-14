require 'csv'

class DailyReportController < ApplicationController
    unloadable

    #
    # 初期表示
    #
    def index

        #ログイン必須
        require_login || return

        #ログインユーザID
        uid = User.current.id

        #ログインユーザおよびそのグループのチケットリストを取得
        @issues = Issue
            .joins("INNER JOIN issue_statuses ist   on ist.id      = issues.status_id ")
            .joins("LEFT OUTER JOIN groups_users gu on gu.group_id = issues.assigned_to_id")
            .joins("LEFT OUTER JOIN versions v      on v.id        = issues.fixed_version_id")
            .joins(:project)
            .select("issues.*, projects.name as project_name, v.name as version_name")
            .where(["(issues.assigned_to_id = :u or gu.user_id = :u) and (ist.is_closed = false or issues.closed_on > (now() - INTERVAL 1 MONTH))", {:u => uid}])
            .all
            .order("projects.id, v.id, issues.id")

        #活動内容のリストを取得
        @activities = Enumeration.where("type = 'TimeEntryActivity'").all
    end

    #
    # 作業報告照会
    #
    def search

        #ログイン必須
        require_login || return

        #当該ユーザの当日の作業報告を取得
        uid = User.current.id
        yyyy = params[:yyyy]
        mm = params[:mm]
        dd = params[:dd]
        @dailyReports = DailyReport.where(["daily_reports.user_id = :u and daily_reports.yyyy = :yyyy and daily_reports.mm = :mm and daily_reports.dd = :dd", {:u => uid, :yyyy => yyyy, :mm => mm, :dd => dd}]).all

        #JSONで返却
        render json: @dailyReports
    end

    #
    # 作業報告登録
    #
    def regist

        #ログイン必須
        require_login || return

        #登録内容を取得
        params[:user_id] = User.current.id
        permitted = params.permit(:id, :user_id, :yyyy, :mm, :dd, :bo_time, :eo_time, :issue_id, :activity_id, :comments)

        id = params[:id]
        if id == '' then
            #ID採番前の場合は追加
            @dailyReport = DailyReport.create(permitted)
        else
            #ID採番済みの場合は照会・更新
            @dailyReport = DailyReport.find(id)
            @dailyReport.update(permitted)
        end

        #日報IDを返却
        render plain: @dailyReport.id
    end

    #
    # 作業報告削除
    #
    def delete

        #ログイン必須
        require_login || return

        #作業報告を削除
        id = params[:id]
        DailyReport.delete(id)

        #日報IDを返却
        render plain: id
    end

    #
    # 作業時間報告
    #
    def decide

        #ログイン必須
        require_login || return

        id = User.current.id
        yyyy = params[:yyyy]
        mm = params[:mm]
        dd = params[:dd]

        #当日の作業時間を一旦削除
        delete = "DELETE "
        delete += "FROM "
        delete += "    time_entries "
        delete += "WHERE "
        delete += "    user_id = '" + id.to_s + "' "
        delete += "    AND spent_on = '" + yyyy + "-" + mm + "-" + dd + "'"
        ActiveRecord::Base.connection.execute(delete)

        #当日の作業報告から作業時間を再登録
        insert = "INSERT "
        insert += "INTO time_entries ( "
        insert += "    SELECT "
        insert += "        null AS id "
        insert += "        , a.project_id "
        insert += "        , a.author_id "
        insert += "        , a.user_id "
        insert += "        , a.issue_id "
        insert += "        , HOUR (a.hours) + MINUTE (a.hours) / 60 AS hours "
        insert += "        , a.comments "
        insert += "        , a.activity_id "
        insert += "        , CONCAT (a.yyyy, '-', a.mm, '-', a.dd) AS spent_on "
        insert += "        , a.yyyy AS tyear "
        insert += "        , a.mm AS tmonth "
        insert += "        , WEEK (CONCAT (a.yyyy, '-', a.mm, '-', a.dd), 3) AS tweek "
        insert += "        , now() AS created_on "
        insert += "        , now() AS updated_on "
        insert += "    FROM "
        insert += "        ( "
        insert += "            SELECT "
        insert += "                p.id AS project_id "
        insert += "                , r.user_id AS author_id "
        insert += "                , r.* "
        insert += "                , TIMEDIFF (r.eo_time, r.bo_time) AS hours "
        insert += "            FROM "
        insert += "                daily_reports r "
        insert += "                INNER JOIN issues i "
        insert += "                    ON i.id = r.issue_id "
        insert += "                INNER JOIN projects p "
        insert += "                    ON p.id = i.project_id "
        insert += "            WHERE "
        insert += "                r.user_id = '" + id.to_s + "' "
        insert += "                AND r.yyyy = '" + yyyy + "' "
        insert += "                AND r.mm = '" + mm + "' "
        insert += "                AND r.dd = '" + dd + "' "
        insert += "        ) a "
        insert += ") "
        ActiveRecord::Base.connection.execute(insert)
    end

    #
    # 月報出力
    #
    def monthly

        #ログイン必須
        require_login || return

        uid = User.current.id
        yyyymm = params[:yyyymm]

        #render json: ActiveRecord::Base.connection.execute("select * from daily_reports where user_id = '" + uid.to_s + "' and concat (yyyy, mm) = '" + yyyymm + "' order by concat (dd, bo_time)")
		#@dailyReports = ActiveRecord::Base.connection.execute("select * from daily_reports where user_id = '" + uid.to_s + "' and concat (yyyy, mm) = '" + yyyymm + "' order by concat (dd, bo_time)")
        @dailyReports = DailyReport
            .joins("INNER JOIN issues i on i.id = daily_reports.issue_id")
            .joins("INNER JOIN trackers t on t.id = i.tracker_id")
            .joins("INNER JOIN projects p on p.id = i.project_id")
            .select("daily_reports.*, i.subject, i.tracker_id, t.name as tracker_name, i.project_id, p.name as project_name")
        	.where(["daily_reports.user_id = :u and concat (daily_reports.yyyy, daily_reports.mm) = :yyyymm", {:u => uid, :yyyymm => yyyymm}])
        	.all
        	.order("dd, bo_time")

		csv_data = CSV.generate(encoding: Encoding::SJIS, row_sep: "\r\n", force_quotes: true) do |csv|
			csv << [
				"id",
				"user_id",
				"yyyy",
				"mm",
				"dd",
				"bo_time",
				"eo_time",
				"issue_id",
				"activity_id",
				"comments",
				
				"subject",
				"tracker_id",
				"tracker_name",
				"project_id",
				"project_name"
			]
			@dailyReports.each do |dailyReport|
				csv << [
					dailyReport.id,
					dailyReport.user_id,
					dailyReport.yyyy,
					dailyReport.mm,
					dailyReport.dd,
					dailyReport.bo_time,
					dailyReport.eo_time,
					dailyReport.issue_id,
					dailyReport.activity_id,
					dailyReport.comments,
					
					dailyReport.subject,
					dailyReport.tracker_id,
					dailyReport.tracker_name,
					dailyReport.project_id,
					dailyReport.project_name
				]
			end
		end
		send_data(csv_data, filename: "月報." + yyyymm + ".csv")
		#redirect_back(fallback_location: root_path)
	end

end
