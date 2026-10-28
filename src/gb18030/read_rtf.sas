/*
详细文档请前往 Github 查阅: https://github.com/Snoopy1866/sas-rtf-toolkit
*/

options cmplib = sasuser.func;

%macro read_rtf(rtf,
                outdata,
                compress      = true,
                del_rtf_ctrl  = true,
                debug         = false
                ) / parmbuff;

    /*打开帮助文档*/
    %if %qupcase(&SYSPBUFF) = %bquote((HELP)) or %qupcase(&SYSPBUFF) = %bquote(()) %then %do;
        X explorer "https://github.com/Snoopy1866/sas-rtf-toolkit/blob/v2/docs/read_rtf.md";
        %goto exit;
    %end;

    /*检查依赖*/
    proc sql noprint;
        select * from DICTIONARY.CATALOGS where libname = "WORK" and memname = "SASMACR" and objname = "_MACRO_TRANSCODE";
    quit;
    %if &SQLOBS = 0 %then %do;
        %put ERROR: 前置依赖缺失，请先加载文件 transcode.sas。;
        %goto exit;
    %end;

    /*声明局部变量*/
    %local i rtf_ref rtf_loc;

    /*声明全局变量*/
    %if not %symexist(readrtf_exit_with_error) %then %do;
        %global readrtf_exit_with_error;
    %end;

    %if not %symexist(readrtf_exit_with_error_text) %then %do;
        %global readrtf_exit_with_error_text;
    %end;

    %let readrtf_exit_with_error = FALSE;
    %let readrtf_exit_with_error_text = %bquote();

    /*变量 compress 处理*/
    %if %upcase(&compress) = TRUE %then %do;
        %let compress = yes;
    %end;
    %else %if %upcase(&compress) = FALSE %then %do;
        %let compress = no;
    %end;
    %else %do;
        %put ERROR: 参数 compress 只能取 TRUE 或 FALSE！;
        %goto exit;
    %end;


    /*1. 获取文件路径*/
    %let reg_rtf_expr = %bquote(/^(?:([A-Za-z_][A-Za-z_0-9]{0,7})|[\x22\x27]?((?:[A-Za-z]:\\|\\\\[^\\\/:?\x22\x27<>|]+)[^\\\/:?\x22\x27<>|]+(?:\\[^\\\/:?\x22\x27<>|]+)*)[\x22\x27]?)$/);
    %let reg_rtf_id = %sysfunc(prxparse(%superq(reg_rtf_expr)));
    %if %sysfunc(prxmatch(&reg_rtf_id, %superq(rtf))) %then %do;
        %let rtf_ref = %sysfunc(prxposn(&reg_rtf_id, 1, %superq(rtf)));
        %let rtf_loc = %sysfunc(prxposn(&reg_rtf_id, 2, %superq(rtf)));

        /*指定的是文件引用名*/
        %if %bquote(&rtf_ref) ^= %bquote() %then %do;
            %if %sysfunc(fileref(&rtf_ref)) > 0 %then %do;
                %put ERROR: 文件名引用 %upcase(&rtf_ref) 未定义！;
                %goto exit;
            %end;
            %else %if %sysfunc(fileref(&rtf_ref)) < 0 %then %do;
                %put ERROR: 文件名引用 %upcase(&rtf_ref) 指向的文件不存在！;
                %goto exit;
            %end;
            %else %if %sysfunc(fileref(&rtf_ref)) = 0 %then %do;
                %let rtf_loc = %qsysfunc(pathname(&rtf_ref, F));
            %end;
        %end;

        /*指定的是物理路径*/
        %if %superq(rtf_loc) ^= %bquote() %then %do;
            %if %sysfunc(fileexist(%superq(rtf_loc))) = 0 %then %do;
                %put ERROR: 文件路径 %superq(rtf_loc) 不存在！;
                %goto exit;
            %end;
        %end;
    %end;
    %else %do;
        %put ERROR: 文件引用名超出 8 字节，或者文件物理地址不符合 Winodws 规范！;
        %goto exit;
    %end;


    /*2. 以纯文本形式读取RTF文件*/
    data _tmp_rtf_data(compress = &compress);
        informat line $32767.;
        format line $32767.;
        length line $32767.;

        infile %unquote(%str(%')&rtf_loc%str(%')) truncover;
        input line $char32767.;
    run;

    %if &SYSERR > 0 %then %do;
        %let readrtf_exit_with_error_text = %superq(SYSERRORTEXT);
        %goto exit_with_error;
    %end;


    /*3. 调整表头（解决由于表头内嵌换行符导致的 RTF 代码折行问题）*/
    data _tmp_rtf_data_polish_header(compress = &compress);
        set _tmp_rtf_data;

        len = length(line);

        length break_line $32767.;

        reg_header_break_id = prxparse("/^(\\pard\\plain\\intbl\\keepn\\sb\d*\\sa\d*\\q[lcr]\\f\d*\\fs\d*\\cf\d*\{.*){\\line}$/o");
        reg_header_break_continue_id = prxparse("/^(.*){\\line}$/o");
        reg_header_break_end_id = prxparse("/^(.*\\cell})$/o");

        retain break_line "";
        retain break_line_found 0;

        if prxmatch(reg_header_break_id, strip(line)) then do; /*发现表头出现折行问题*/
            break_line = catt(break_line, prxposn(reg_header_break_id, 1, strip(line)));
            break_line_found = 1;
            delete;
        end;
        else if prxmatch(reg_header_break_continue_id, strip(line)) then do; /*发现连续折行*/
            if break_line_found = 1 then do;
                break_line = catt(break_line, "|", prxposn(reg_header_break_continue_id, 1, strip(line)));
                delete;
            end;
        end;
        else if prxmatch(reg_header_break_end_id, strip(line)) then do; /*折行结束*/
            if break_line_found = 1 then do;
                break_line = catt(break_line, "|", prxposn(reg_header_break_end_id, 1, strip(line)));
                line = break_line;

                break_line_found = 0;
                break_line = "";
            end;
        end;
    run;


    /*5. 调整数据行（解决由于超长字符串导致的 RTF 代码折行问题）*/
    data _tmp_rtf_data_polish_body(compress = &compress);
        set _tmp_rtf_data_polish_header;

        length line_data_part $32767 line_data_part_buffer $32767;

        reg_data_line_start_id = prxparse("/^\\pard\\plain\\intbl(?:\\keepn)?\\sb\d*\\sa\d*\\q[lcr]\\f\d*\\fs\d*\\cf\d*\{([\x20-\x7e\x08-\x0d]*)$/o");
        reg_data_line_mid_id   = prxparse("/^((?:\\'[0-9A-F]{2}|\\u\d{1,5};|[\x20-\x7e\x08-\x0d])*)$/o");
        reg_data_line_end_id   = prxparse("/^((?:\\'[0-9A-F]{2}|\\u\d{1,5};|[\x20-\x7e\x08-\x0d])*)\\cell\}$/o");

        retain line_data_part "";
        retain line_data_part_found 0;

        if prxmatch(reg_data_line_start_id, strip(line)) then do;
            line_data_part_buffer = prxposn(reg_data_line_start_id, 1, strip(line));
            /*正则表达式使用了ASCII字符集合，导致某些非数据行被错误地匹配，需要进一步筛选*/
            if find(line_data_part_buffer, "\cell}") = 0 then do; /*控制字\cell}不可能出现在数据行开头*/
                line_data_part_found = 1;
                line_data_part = strip(line);
                delete;
            end;
        end;

        if line_data_part_found = 1 then do;
            if prxmatch(reg_data_line_mid_id, strip(line)) then do;
                if find(strip(line), "\shppict") > 0 then do; /*控制字 \shppict 指定 Word 97 图片，它通常出现在页眉 logo 中，不可能在数据行中出现*/
                    line_data_part_found = 0;
                    line_data_part = "";
                end;
                else do;
                    line_data_part_buffer = prxposn(reg_data_line_mid_id, 1, strip(line));
                    /*正则表达式使用了ASCII字符集合，导致某些非数据行被错误地匹配，需要进一步筛选*/
                    if find(line_data_part_buffer, "\cell}") = 0 and substr(line_data_part_buffer, 1, 5) ^= "\pard" then do; /*控制字 \cell}, \pard 不可能出现在数据行中间*/
                        if line_data_part_found = 1 then do;
                            line_data_part = cats(line_data_part, line_data_part_buffer);
                            delete;
                        end;
                    end;
                end;
            end;

            if prxmatch(reg_data_line_end_id, strip(line)) then do;
                line_data_part_buffer = prxposn(reg_data_line_end_id, 1, strip(line));
                if line_data_part_found = 1 then do;
                    line_data_part = cats(line_data_part, line_data_part_buffer, "\cell}");
                    line = line_data_part;

                    line_data_part_found = 0;
                    line_data_part = "";
                end;
            end;
        end;
    run;


    /*4. 识别表格数据*/
    %let is_outlinelevel_found = 0;

    data _tmp_rtf_raw(compress = &compress);
        set _tmp_rtf_data_polish_body;
        
        /*变量个数*/
        retain var_n 0;

        /*变量位置*/;
        retain var_pointer 0;

        /*是否发现表格标题*/
        retain is_outlinelevel_found 0;

        /*是否发现表头*/
        retain is_header_found 0;

        /*是否发现表头单元格边框位置定义*/
        retain is_header_def_found 0;

        /*表头单元格层数位置(从上往下递增)*/
        retain header_cell_level 0;

        /*表头单元格左侧边框位置*/
        retain header_cell_left_padding 0;

        /*表头单元格右侧边框位置*/
        retain header_cell_right_padding 0;

        /*是否发现表格数据*/
        retain is_data_found 0;

        /*
        当前 rtf 代码指向的变量位置
        obs_var_pointer 随着读取的 rtf 数据行数自增，最大不超过 var_n，
        且在下一段数据的起始位置被重置为 0
        */
        retain obs_var_pointer 0;

        /*观测序号*/
        retain obs_seq 0;


        /*定义正则表达式筛选表头和数据*/
        reg_outlinelevel_id    = prxparse("/\\outlinelevel\d/o");
        reg_header_line_id     = prxparse("/\\trowd\\trkeep\\trhdr\\trq[lcr]/o");
        reg_header_def_line_id = prxparse("/\\clbrdr[tlbr]\\brdrs\\brdrw\d*\\brdrcf\d*(?:\\clbrdr[tlbr]\\brdrs\\brdrw\d*\\brdrcf\d*)*\\cltxlrt[bl]\\clvertal[tcb](?:\\clcbpat\d*)?\\cellx(\d+)/o");

        %let data_line_ctrl_prefix_or_suffix = %nrbquote(\\animtext\d*\\ul\d*\\strike\d*\\b\d*\\i\d*\\f\d*\\fs\d*\\cf\d*\s*);
        reg_data_line_id       = prxparse("/^\\pard\\plain\\intbl(?:\\keepn)?\\sb\d*\\sa\d*\\q[lcr]\\f\d*\\fs\d*\\cf\d*\{(?:&data_line_ctrl_prefix_or_suffix)?([\x20-\x7e\x08-\x0d]*?)(?:&data_line_ctrl_prefix_or_suffix)?\\cell\}$/o");
        reg_sect_line_id       = prxparse("/\\sect\\sectd\\linex\d*\\endnhere\\pgwsxn\d*\\pghsxn\d*\\lndscpsxn\\headery\d*\\footery\d*\\marglsxn\d*\\margrsxn\d*\\margtsxn\d*\\margbsxn\d*/o");


        length context_raw $32767;

        /*发现表格标题*/
        if prxmatch(reg_outlinelevel_id, strip(line)) then do;
            if is_outlinelevel_found = 0 then do;
                is_outlinelevel_found = 1;
                call symputx("is_outlinelevel_found", 1);
            end;
        end;

        /*发现表头*/
        else if prxmatch(reg_header_line_id, strip(line)) then do;
            is_header_found = 1;
            header_cell_level + 1;
        end;

        /*发现表头单元格边框位置的定义*/
        else if prxmatch(reg_header_def_line_id, strip(line)) then do;
            is_header_def_found = 1;
            header_cell_left_padding = header_cell_right_padding;
            header_cell_right_padding = input(prxposn(reg_header_def_line_id, 1, strip(line)), 8.);

            var_pointer + 1;
            var_n = max(var_n, var_pointer);
        end;


        /*发现数据*/
        else if prxmatch(reg_data_line_id, strip(line)) then do;
            if is_outlinelevel_found = 1 then do; /*限定在表格标题后的数据行，排除页眉中的数据*/
                if is_header_found = 1 then do; /*紧跟在控制字 \trhdr 后的数据行，实际上就是表头*/
                    if not prxmatch(reg_header_def_line_id, strip(line)) and is_header_def_found = 1 then do; /*表头边框位置定义已结束，将指针重置为 0*/
                        var_pointer = 0;
                    end;
                    flag_header = "Y";
                    var_pointer + 1;
                    var_n = max(var_n, var_pointer);
                    context_raw = prxposn(reg_data_line_id, 1, strip(line));
                end;
                else do; /*数据行*/
                    flag_data = "Y";
                    is_data_found = 1;
                    obs_var_pointer + 1;
                    if obs_var_pointer = 1 then do;
                        obs_seq + 1;
                    end;
                    context_raw = prxposn(reg_data_line_id, 1, strip(line));

                    header_cell_level = 0;
                end;
            end;

            is_header_def_found = 0;
            header_cell_left_padding = 0;
            header_cell_right_padding = 0;
        end;

        /*发现分节符*/
        else if prxmatch(reg_sect_line_id, strip(line)) then do;
            is_outlinelevel_found = 0;
        end;

        /*其他情况*/
        else do;
            if header_cell_right_padding > 0 then do;
                is_header_def_found = 0;
                header_cell_left_padding = 0;
                header_cell_right_padding = 0;
            end;

            if var_pointer > 0 then do; /*表头定义暂时结束，将指针位置重置为 0*/
                is_header_found = 0;
                var_pointer = 0;
            end;


            if obs_var_pointer = var_n then do; /*数据行定义暂时结束，将指针位置重置为 0*/
                obs_var_pointer = 0;
            end;
        end;
    run;

    %if &is_outlinelevel_found = 0 %then %do;
        %put ERROR: 在 RTF 文件中未发现大纲级别的标题，请使用控制字 \outlinelevel 生成 RTF 文件的标题！;
        %goto exit;
    %end;

    /*5. 删除 RTF 控制字*/
    %if %upcase(&del_rtf_ctrl) = TRUE %then %do;
        /*控制字-空的分组*/
        %let reg_ctrl_1 = %bquote({\s*}|(?<!\\)[{}]);
        /*控制字-缩进*/
        %let reg_ctrl_2 = %bquote(\\[flr]i\d+);
        /*控制字-取消上下标*/
        %let reg_ctrl_3 = %bquote(\\nosupersub);

        /*控制字-上标*/
        %let reg_ctrl_4 = %bquote(\{?\\super\s*((?:\\[\\\{\}]|[^\\\{\}])+)\}?); /*
                                                                               https://github.com/Snoopy1866/sas-rtf-toolkit/issues/20
                                                                               https://github.com/Snoopy1866/sas-rtf-toolkit/issues/26
                                                                              */

        /*控制字-转义字符*/
        %let reg_ctrl_5 = %bquote(\\([\{\}\\]));

        /*合并reg_ctrl_1 ~ reg_ctrl_n*/
        %unquote(%nrstr(%%let reg_ctrl =)) %sysfunc(catx(%bquote(|) %unquote(%do i = 1 %to 3; %bquote(,)%bquote(&&reg_ctrl_&i) %end;)));

        data _tmp_rtf_raw_del_ctrl(compress = &compress);
            set _tmp_rtf_raw;
            reg_rtf_del_ctrl_id   = prxparse("s/(?:&reg_ctrl)\s*//o");
            reg_rtf_del_ctrl_id_4 = prxparse("s/(?:&reg_ctrl_4)\s*/$1/o");
            reg_rtf_del_ctrl_id_5 = prxparse("s/(?:&reg_ctrl_5)/$1/o");
            if flag_header = "Y" or flag_data = "Y" then do;
                context_raw = prxchange(reg_rtf_del_ctrl_id,   -1, strip(context_raw));
                context_raw = prxchange(reg_rtf_del_ctrl_id_4, -1, strip(context_raw));
                context_raw = prxchange(reg_rtf_del_ctrl_id_5, -1, strip(context_raw));
            end;
        run;
    %end;
    %else %do;
        data _tmp_rtf_raw_del_ctrl(compress = &compress);
            set _tmp_rtf_raw;
        run;
    %end;


    /*6. 开始转码*/
    data _tmp_rtf_context(compress = &compress);
        set _tmp_rtf_raw_del_ctrl;
        if flag_header = "Y" or flag_data = "Y" then do;
            context = cell_transcode(context_raw);
        end;
    run;


    /*7. 生成SAS数据集*/
    proc sort data = _tmp_rtf_context(where = (flag_data = "Y")) out = _tmp_rtf_context_sorted(compress = &compress) presorted;
        by obs_seq obs_var_pointer;
    run;

    proc transpose data = _tmp_rtf_context_sorted out = _tmp_outdata prefix = COL;
        var context;
        id obs_var_pointer;
        by obs_seq;
    run;


    /*8. 处理变量标签*/
    proc sql noprint;
        /*获取所有层级的标签*/
        create table _tmp_rtf_header as
            select
                a.header_cell_level,
                a.var_pointer,
                a.header_cell_left_padding,
                a.header_cell_right_padding,
                b.context
            from _tmp_rtf_context(where = (is_header_def_found = 1)) as a left join _tmp_rtf_context(where = (flag_header = "Y")) as b
                     on a.header_cell_level = b.header_cell_level and a.var_pointer = b.var_pointer;
        /*获取标签最大层数*/
        select max(header_cell_level) into : max_header_level trimmed from _tmp_rtf_header;

        /*合并所有层级的标签*/
        create table _tmp_rtf_header_expand as
            select
                a&max_header_level..var_pointer,
                catx("|", %unquote(%do i = 1 %to %eval(&max_header_level - 1);
                                       %bquote(a&i..context)%bquote(,)
                                   %end;)
                                   a&max_header_level..context)
                    as header_context length = 32767 /*这里用 length =32767 是有必要的，有时候解析 utf8 字符时会出现长度异常的问题，原因未知*/
            from _tmp_rtf_header(where = (header_cell_level = &max_header_level)) as a&max_header_level
                %do i = %eval(&max_header_level - 1) %to 1 %by -1;
                    left join _tmp_rtf_header(where = (header_cell_level = &i)) as a&i
                    on a&max_header_level..header_cell_left_padding >= a&i..header_cell_left_padding and a&max_header_level..header_cell_right_padding <= a&i..header_cell_right_padding
                %end;
                ;
    quit;

    /*标签进一步处理*/
    data _tmp_rtf_header_expand_polish;
        set _tmp_rtf_header_expand;
        reg_header_control_word_id = prxparse("s/\\animtext\d*\\ul\d*\\strike\d*\\b\d*\\i\d*\\f\d*\\fs\d*\\cf\d*\s*//o");
        
        header_context = prxchange(reg_header_control_word_id, -1, strip(header_context));

        if substr(header_context, 1, 1) = "|" then do;
            header_context = substr(header_context, 2);
        end;

        if header_context = "" then do;
            header_context = "空标签";
        end;
    run;


    /*9. 修改SAS数据集的属性*/
    proc sql noprint;
        /*获取变量个数*/
        select nvar - 2 into : var_n from DICTIONARY.TABLES where libname = "WORK" and memname = "_TMP_OUTDATA";
        
        %do i = 1 %to &var_n;
            /*获取变量实际所需长度*/
            select max(length(col&i)) into : var_&i._maxlen from _tmp_outdata;

            /*获取变量标签*/
            select header_context into : var_&i._label trimmed from _tmp_rtf_header_expand_polish where var_pointer = &i;
        %end;

        alter table _tmp_outdata
            modify %do i = 1 %to &var_n;
                       COL&i char(&&var_&i._maxlen) label = "%superq(var_&i._label)",
                   %end;
                       OBS_SEQ label = "序号";
        alter table _tmp_outdata
            drop _NAME_;
    quit;
    

    /*10. 最终输出*/
    data &outdata;
        set _tmp_outdata;
    run;

    %goto exit;


    /*异常退出*/
    %exit_with_error:
    %let readrtf_exit_with_error = TRUE;

    /*正常退出*/
    %exit:
    /*11. 清除中间数据集*/
    %if %upcase(&debug) = FALSE %then %do;
        proc datasets library = work nowarn noprint;
            delete _tmp_outdata
                   _tmp_rtf_data
                   _tmp_rtf_data_polish_header
                   _tmp_rtf_data_polish_body
                   _tmp_rtf_context
                   _tmp_rtf_context_sorted
                   _tmp_rtf_header
                   _tmp_rtf_header_expand
                   _tmp_rtf_header_expand_polish
                   _tmp_rtf_raw
                   _tmp_rtf_raw_del_ctrl
                  ;
        quit;
    %end;

    %put NOTE: 宏 read_rtf 已结束运行！;
%mend;

