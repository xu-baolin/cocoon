// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'utils.dart';

/// Maximum amount of time a single task is allowed to take to run.
///
/// If exceeded the task is considered to have failed.
const Duration taskTimeout = const Duration(minutes: 10);

/// Slightly longer than [taskTimeout] that gives the task runner a chance to
/// clean-up before forcefully quitting it.
const Duration taskTimeoutWithGracePeriod = const Duration(minutes: 11);

/// Represents a unit of work performed on the dashboard build box that can
/// succeed, fail and be retried independently of others.
abstract class Task {
  Task(this.name);

  /// The name of the task that shows up in log messages.
  ///
  /// This should be as unique as possible to avoid confusion.
  final String name;

  /// Performs actual work.
  Future<TaskResultData> run();
}

/// Runs a queue of tasks; collects results.
class TaskRunner {
  TaskRunner(this.revision, this.golemRevision, this.tasks);

  /// Flutter repository revision at which this runner ran.
  final String revision;

  /// Revision _number_ as understood by Golem.
  ///
  /// See [computeGolemRevision].
  final int golemRevision;
  final List<Task> tasks;

  Future<BuildResult> run() async {
    List<TaskResult> results = <TaskResult>[];

    for (Task task in tasks) {
      section('Running task ${task.name}');
      TaskResult result;
      try {
        TaskResultData data = await task.run();
        if (data != null)
          result = new TaskResult.success(task, revision, data);
        else
          result = new TaskResult.failure(task, revision, 'Task data missing');
      } catch (taskError, taskErrorStack) {
        String message = '${task.name} failed: $taskError';
        if (taskErrorStack != null) {
          message += '\n\n$taskErrorStack';
        }
        print('');
        print(message);
        result = new TaskResult.failure(task, revision, message);
      }
      results.add(result);
      section('Task ${task.name} ${result.succeeded ? "succeeded" : "failed"}.');
    }

    return new BuildResult(golemRevision, results);
  }
}

/// All results accumulated from a build session.
class BuildResult {
  BuildResult(this.golemRevision, this.results);

  final int golemRevision;

  /// Individual task results.
  final List<TaskResult> results;

  /// Whether the overall build failed.
  ///
  /// We consider the build as failed if at least one task fails.
  bool get failed => results.any((TaskResult res) => res.failed);

  /// The opposite of [failed], i.e. all tasks succeeded.
  bool get succeeded => !failed;

  /// The number of failed tasks.
  int get failedTaskCount => results.fold(0, (int previous, TaskResult res) => previous + (res.failed ? 1 : 0));
}

/// A result of running a single task.
class TaskResult {

  /// Constructs a successful result.
  TaskResult.success(this.task, this.revision, this.data)
    : this.succeeded = true,
      this.message = 'success';

  /// Constructs an unsuccessful result.
  TaskResult.failure(this.task, this.revision, this.message)
    : this.succeeded = false,
      this.data = null;

  /// The task that was run.
  final Task task;

  /// Whether the task succeeded.
  final bool succeeded;

  /// The revision of Flutter repo at which this result was generated.
  final String revision;

  /// Data generated by the task that will be uploaded to Firebase.
  final TaskResultData data;

  /// Whether the task failed.
  bool get failed => !succeeded;

  /// Explains the result in a human-readable format.
  final String message;
}

/// Data generated by the task that will be uploaded to Firebase.
class TaskResultData {
  TaskResultData(this.json, {this.benchmarkScoreKeys}) {
    const JsonEncoder prettyJson = const JsonEncoder.withIndent('  ');
    if (benchmarkScoreKeys != null) {
      for (String key in benchmarkScoreKeys) {
        if (!json.containsKey(key)) {
          throw 'Invalid Golem score key "$key". It does not exist in task result data ${prettyJson.convert(json)}';
        }
      }
    }
  }

  factory TaskResultData.fromFile(File file, {List<String> benchmarkScoreKeys}) {
    return new TaskResultData(JSON.decode(file.readAsStringSync()), benchmarkScoreKeys: benchmarkScoreKeys);
  }

  /// Task-specific JSON data
  final Map<String, dynamic> json;

  /// Keys in [json] that store scores that will be submitted to Golem.
  ///
  /// Each key is also part of a benchmark's name tracked by Golem.
  /// A benchmark name is computed by combining [Task.name] with a key
  /// separated by a dot. For example, if a task's name is
  /// `"complex_layout__start_up"` and score key is
  /// `"engineEnterTimestampMicros"`, the score will be submitted to Golem under
  /// `"complex_layout__start_up.engineEnterTimestampMicros"`.
  ///
  /// This convention reduces the amount of configuration that needs to be done
  /// to submit benchmark scores to Golem.
  final List<String> benchmarkScoreKeys;
}