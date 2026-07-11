// This implementation is adapted from the project "login-ZJU" by 5dbwat4(https://github.com/5dbwat4/login-ZJU) under the MIT License.
// See: https://github.com/5dbwat4/login-ZJU/blob/main/src/utils/fetch-with-cookie.ts

import 'dart:convert';
import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/http/zjuServices/exceptions.dart';
import 'package:celechron/utils/tuple.dart';
import 'package:celechron/model/todo.dart';

class Courses {
  DatabaseHelper? _db;
  Cookie? _session;
  Cookie? _iPlanetDirectoryPro;

  set db(DatabaseHelper? db) {
    _db = db;
  }

  Future<Tuple<Exception?, List<Todo>>> getTodo(HttpClient httpClient,
      [String? currentSemesterName]) async {
    try {
      // Step 1: 确保有 session
      if (_session == null) {
        if (_iPlanetDirectoryPro != null) {
          await login(httpClient, _iPlanetDirectoryPro);
        } else {
          throw ExceptionWithMessage("未登录");
        }
      }

      // Step 2: POST /api/my-courses 获取课程列表
      final coursesBody = await _authPost(
        httpClient,
        Uri.parse("https://courses.zju.edu.cn/api/my-courses"),
        {
          "fields":
              "id,name,display_name,department(id,name),is_started,is_closed,start_date,end_date,semester(id,code)",
          "page": 1,
          "page_size": 50,
          "conditions": {
            "status": ["ongoing", "notStarted"],
            "keyword": "",
            "classify_type": "recently_started"
          },
          "showScorePassedStatus": false,
        },
      );
      final coursesJson = jsonDecode(coursesBody) as Map<String, dynamic>;
      final courseList = (coursesJson["courses"] as List)
          .map((c) => c as Map<String, dynamic>)
          .toList();

      // Step 3: 过滤活跃课程
      final activeCourses = filterBySemester(courseList, currentSemesterName);

      // Step 4: 逐课程抓取作业
      final List<Map<String, dynamic>> allTodoItems = [];
      int successCourses = 0;
      int failCourses = 0;
      for (final course in activeCourses) {
        final courseId = course["id"];
        final courseName = (course["display_name"] as String?) ??
            (course["name"] as String?) ??
            "未知课程";

        try {
          final hwBody = await _authGet(
            httpClient,
            Uri.parse(
                "https://courses.zju.edu.cn/api/courses/$courseId/homework-activities"
                "?conditions=%7B%22itemsSortBy%22%3A%7B%22predicate%22%3A%22module%22%2C%22reverse%22%3Afalse%7D%7D"
                "&page=1&page_size=50&reloadPage=false"),
          );
          final hwJson = jsonDecode(hwBody) as Map<String, dynamic>;
          final activities = (hwJson["homework_activities"] as List?)
                  ?.cast<Map<String, dynamic>>() ??
              [];
          successCourses++;

          for (final act in activities) {
            final type = act["type"] as String? ?? "";
            final submitted = act["submitted"] as bool? ?? false;
            final isClosed = act["is_closed"] as bool? ?? false;

            if (type == "homework" && !submitted && !isClosed) {
              allTodoItems.add({
                "id": (act["id"] as dynamic).toString(),
                "title": (act["title"] as String?) ?? "未命名作业",
                "course_name": courseName,
                "end_time": (act["deadline"] as String?) ??
                    (act["end_time"] as String?),
                "is_student": true,
              });
            }
          }
        } catch (courseErr) {
          failCourses++;
        }
      }

      if (activeCourses.isNotEmpty && successCourses == 0) {
        throw ExceptionWithMessage("所有课程作业抓取失败");
      }

      if (failCourses > 0) {
        throw ExceptionWithMessage("$failCourses 门课程作业抓取失败");
      }

      final cacheData = {"todo_list": allTodoItems};
      final cacheBody = jsonEncode(cacheData);
      _db?.setCachedWebPage("courses_todo", cacheBody);

      final todos = Todo.getAllFromCourses(cacheData);
      return Tuple(null, todos);
    } catch (e) {
      var exception =
          e is SocketException ? ExceptionWithMessage("网络错误") : e as Exception;
      var todos = Todo.getAllFromCourses(
          (jsonDecode(_db?.getCachedWebPage("courses_todo") ?? '{}')));
      return Tuple(exception, todos);
    }
  }

  // ---- 按学期过滤 ----

  /// 按当前学期过滤课程列表。
  /// [currentSemesterName] 格式如 "2025-2026春夏"、"2026-2027短"。
  /// 保留：同学年 + 匹配季节，以及未来学年。
  static List<Map<String, dynamic>> filterBySemester(
      List<Map<String, dynamic>> courseList, String? currentSemesterName) {
    String currentYearPrefix;
    List<String> matchingSeasons;

    if (currentSemesterName != null) {
      final sm = RegExp(r'^(\d{4}-\d{4})(.+)$').firstMatch(currentSemesterName);
      if (sm != null) {
        currentYearPrefix = sm.group(1)!;
        final season = sm.group(2)!;
        if (season == "秋冬") {
          matchingSeasons = ["秋冬", "秋", "冬"];
        } else if (season == "春夏") {
          matchingSeasons = ["春夏", "春", "夏"];
        } else {
          matchingSeasons = [season];
        }
      } else {
        final now = DateTime.now();
        currentYearPrefix = '${now.year - 1}-${now.year}';
        matchingSeasons = ["春夏", "秋冬"];
      }
    } else {
      final now = DateTime.now();
      currentYearPrefix = '${now.year - 1}-${now.year}';
      matchingSeasons = ["春夏", "秋冬"];
    }

    final result = courseList.where((c) {
      final isClosed = c["is_closed"] as bool? ?? false;
      if (isClosed) return false;
      final code = (c["semester"] as Map<String, dynamic>?)?["code"] as String?;
      if (code == null) return false;

      final m = RegExp(r'^(\d{4}-\d{4})(.+)$').firstMatch(code);
      if (m == null) return false;
      final yearPrefix = m.group(1)!;
      final seasonPart = m.group(2)!;

      // 未来学年 → 总是包含
      if (yearPrefix.compareTo(currentYearPrefix) > 0) return true;

      // 同学年：检查季节是否匹配
      if (yearPrefix == currentYearPrefix) {
        return matchingSeasons.contains(seasonPart);
      }

      return false;
    }).toList();

    return result;
  }

  // ---- HTTP 辅助（带 session 过期自动重登） ----

  Future<String> _authGet(HttpClient httpClient, Uri uri) async {
    var request = await httpClient.getUrl(uri).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
    request.cookies.add(_session!);
    var response = await request.close().timeout(const Duration(seconds: 8),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
    var body = await response.transform(utf8.decoder).join();

    if (body.contains("cas/login") || body.contains("统一身份认证")) {
      _session = null;
      if (_iPlanetDirectoryPro != null) {
        await login(httpClient, _iPlanetDirectoryPro);
        request = await httpClient.getUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw ExceptionWithMessage("请求超时"));
        request.cookies.add(_session!);
        response = await request.close().timeout(const Duration(seconds: 8),
            onTimeout: () => throw ExceptionWithMessage("请求超时"));
        body = await response.transform(utf8.decoder).join();
      }
    }
    return body;
  }

  Future<String> _authPost(
      HttpClient httpClient, Uri uri, Map<String, dynamic> reqBody) async {
    var request = await httpClient.postUrl(uri).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
    request.headers.contentType = ContentType.json;
    request.cookies.add(_session!);
    request.write(jsonEncode(reqBody));
    var response = await request.close().timeout(const Duration(seconds: 8),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
    var body = await response.transform(utf8.decoder).join();

    if (body.contains("cas/login") || body.contains("统一身份认证")) {
      _session = null;
      if (_iPlanetDirectoryPro != null) {
        await login(httpClient, _iPlanetDirectoryPro);
        request = await httpClient.postUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw ExceptionWithMessage("请求超时"));
        request.headers.contentType = ContentType.json;
        request.cookies.add(_session!);
        request.write(jsonEncode(reqBody));
        response = await request.close().timeout(const Duration(seconds: 8),
            onTimeout: () => throw ExceptionWithMessage("请求超时"));
        body = await response.transform(utf8.decoder).join();
      }
    }
    return body;
  }

  // ---- 登录 / 登出 ----

  Future<bool> login(HttpClient httpClient, Cookie? iPlanetDirectoryPro) async {
    late HttpClientRequest request;
    late HttpClientResponse response;

    if (iPlanetDirectoryPro == null) {
      throw ExceptionWithMessage("iPlanetDirectoryPro无效");
    }

    _iPlanetDirectoryPro = iPlanetDirectoryPro;

    var cookies = <Cookie>[iPlanetDirectoryPro];

    Future<void> getWithCookies(String url) async {
      request = await httpClient.getUrl(Uri.parse(url)).timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw ExceptionWithMessage("请求超时"));
      request.followRedirects = false;
      request.cookies.addAll(cookies);
      response = await request.close().timeout(const Duration(seconds: 8),
          onTimeout: () => throw ExceptionWithMessage("请求超时"));
      cookies.addAll(response.cookies);
      response.drain();
      if (response.isRedirect) {
        if (response.headers.value(HttpHeaders.locationHeader)! ==
            ("https://courses.zju.edu.cn/user/index")) {
          _session =
              response.cookies.firstWhere((cookie) => cookie.name == "session");
          return;
        }
        return await getWithCookies(
            response.headers.value(HttpHeaders.locationHeader) as String);
      }
    }

    await getWithCookies("https://courses.zju.edu.cn/user/index");
    if (_session == null) {
      throw ExceptionWithMessage("无法获取session");
    }

    return true;
  }

  void logout() {
    _session = null;
  }
}
