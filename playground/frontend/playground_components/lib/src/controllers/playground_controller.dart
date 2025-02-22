/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../cache/example_cache.dart';
import '../models/example.dart';
import '../models/example_base.dart';
import '../models/example_loading_descriptors/empty_example_loading_descriptor.dart';
import '../models/example_loading_descriptors/example_loading_descriptor.dart';
import '../models/example_loading_descriptors/examples_loading_descriptor.dart';
import '../models/example_loading_descriptors/standard_example_loading_descriptor.dart';
import '../models/example_loading_descriptors/user_shared_example_loading_descriptor.dart';
import '../models/intents.dart';
import '../models/sdk.dart';
import '../models/shortcut.dart';
import '../repositories/code_repository.dart';
import '../services/symbols/loaders/map.dart';
import '../services/symbols/symbols_notifier.dart';
import 'code_runner.dart';
import 'example_loaders/examples_loader.dart';
import 'output_filter_type_controller.dart';
import 'snippet_editing_controller.dart';

const kTitleLength = 25;
const kExecutionTimeUpdate = 100;
const kPrecompiledDelay = Duration(seconds: 1);
const kTitle = 'Catalog';
const kExecutionCancelledText = '\nPipeline cancelled';
const kPipelineOptionsParseError =
    'Failed to parse pipeline options, please check the format (example: --key1 value1 --key2 value2), only alphanumeric and ",*,/,-,:,;,\',. symbols are allowed';
const kCachedResultsLog =
    'The results of this example are taken from the Apache Beam Playground cache.\n';

/// The main state object for the code and its running.
class PlaygroundController with ChangeNotifier {
  final ExampleCache exampleCache;
  final ExamplesLoader examplesLoader;
  final OutputFilterTypeController outputTypeController =
      OutputFilterTypeController();

  late final CodeRunner codeRunner;

  final _snippetEditingControllers = <Sdk, SnippetEditingController>{};

  Sdk? _sdk;

  PlaygroundController({
    required this.exampleCache,
    required this.examplesLoader,
    CodeRepository? codeRepository,
  }) {
    examplesLoader.setPlaygroundController(this);

    codeRunner = CodeRunner(
      codeRepository: codeRepository,
      snippetEditingControllerGetter: requireSnippetEditingController,
    )..addListener(notifyListeners);
  }

  SnippetEditingController _getOrCreateSnippetEditingController(
    Sdk sdk, {
    required bool loadDefaultIfNot,
  }) {
    final existing = _snippetEditingControllers[sdk];
    if (existing != null) {
      return existing;
    }

    final result = SnippetEditingController(sdk: sdk);
    _snippetEditingControllers[sdk] = result;
    result.addListener(notifyListeners);

    if (loadDefaultIfNot) {
      // TODO(alexeyinkin): Show loading indicator if loading.
      examplesLoader.loadDefaultIfAny(sdk);
    }

    return result;
  }

  // TODO(alexeyinkin): Return full, then shorten, https://github.com/apache/beam/issues/23250
  String get examplesTitle {
    final name = snippetEditingController?.example?.name ?? kTitle;
    return name.substring(0, min(kTitleLength, name.length));
  }

  Example? get selectedExample => snippetEditingController?.example;

  Sdk? get sdk => _sdk;

  SnippetEditingController? get snippetEditingController =>
      _snippetEditingControllers[_sdk];

  SnippetEditingController requireSnippetEditingController() {
    final controller = snippetEditingController;

    if (controller == null) {
      throw Exception('SDK is not set.');
    }

    return controller;
  }

  String? get source =>
      snippetEditingController?.activeFileController?.codeController.fullText;

  // TODO(alexeyinkin): Single source of truth for whether graph is supported, https://github.com/apache/beam/issues/23251
  bool get graphAvailable =>
      selectedExample?.type != ExampleType.test &&
      [Sdk.java, Sdk.python].contains(sdk);

  /// If no SDK is selected, sets it to [sdk] and creates an empty state for it.
  void setEmptyIfNoSdk(Sdk sdk) {
    if (_sdk != null) {
      return;
    }

    setExample(
      Example.empty(sdk),
      descriptor: EmptyExampleLoadingDescriptor(sdk: sdk),
      setCurrentSdk: true,
    );
  }

  /// If the state for [sdk] does not exists, creates an empty state for it.
  void setEmptyIfNotExists(
    Sdk sdk, {
    required bool setCurrentSdk,
  }) {
    if (_snippetEditingControllers.containsKey(sdk)) {
      return;
    }

    setExample(
      Example.empty(sdk),
      descriptor: EmptyExampleLoadingDescriptor(sdk: sdk),
      setCurrentSdk: setCurrentSdk,
    );
  }

  Future<void> setExampleBase(ExampleBase exampleBase) async {
    final snippetEditingController = _getOrCreateSnippetEditingController(
      exampleBase.sdk,
      loadDefaultIfNot: false,
    );

    if (!snippetEditingController.lockExampleLoading()) {
      return;
    }

    notifyListeners();

    try {
      final example = await exampleCache.loadExampleInfo(exampleBase);
      // TODO(alexeyinkin): setCurrentSdk = false when we do
      //  per-SDK output and run status.
      //  Now using true to reset the output and run status.
      //  https://github.com/apache/beam/issues/23248
      final descriptor = StandardExampleLoadingDescriptor(
        sdk: example.sdk,
        path: example.path,
      );

      setExample(
        example,
        descriptor: descriptor,
        setCurrentSdk: true,
      );

      // ignore: avoid_catches_without_on_clauses
    } catch (ex) {
      snippetEditingController.releaseExampleLoading();
      notifyListeners();
      rethrow;
    }
  }

  void setExample(
    Example example, {
    required ExampleLoadingDescriptor descriptor,
    required bool setCurrentSdk,
  }) {
    if (setCurrentSdk) {
      _sdk = example.sdk;
      final controller = _getOrCreateSnippetEditingController(
        example.sdk,
        loadDefaultIfNot: false,
      );

      controller.setExample(example, descriptor: descriptor);
      _ensureSymbolsInitialized();
    } else {
      final controller = _getOrCreateSnippetEditingController(
        example.sdk,
        loadDefaultIfNot: false,
      );
      controller.setExample(example, descriptor: descriptor);
    }

    codeRunner.clearResult();
    notifyListeners();
  }

  void setSdk(
    Sdk sdk, {
    bool notify = true,
  }) {
    _sdk = sdk;
    _getOrCreateSnippetEditingController(
      sdk,
      loadDefaultIfNot: true,
    );
    _ensureSymbolsInitialized();

    if (notify) {
      notifyListeners();
    }
  }

  void _ensureSymbolsInitialized() {
    final mode = _sdk?.highlightMode;
    final loader = symbolLoadersByMode[mode];

    if (mode == null || loader == null) {
      return;
    }

    GetIt.instance.get<SymbolsNotifier>().addLoaderIfNot(mode, loader);
  }

  Future<void> reset() async {
    await codeRunner.cancelRun();
    snippetEditingController?.reset();
    codeRunner.clearResult();
  }

  void resetErrorMessageText() {
    codeRunner.resetErrorMessageText();
  }

  void setPipelineOptions(String options) {
    final controller = requireSnippetEditingController();
    controller.pipelineOptions = options;
    notifyListeners();
  }

  Future<UserSharedExampleLoadingDescriptor> saveSnippet() async {
    final snippetController = requireSnippetEditingController();
    final files = snippetController.getFiles();

    final snippetId = await exampleCache.saveSnippet(
      files: files,
      pipelineOptions: snippetController.pipelineOptions,
      sdk: snippetController.sdk,
    );

    final sharedExample = Example(
      datasets: snippetController.example?.datasets ?? [],
      files: files,
      name: files.first.name,
      path: snippetId,
      sdk: snippetController.sdk,
      type: ExampleType.example,
    );

    final descriptor = UserSharedExampleLoadingDescriptor(
      sdk: sharedExample.sdk,
      snippetId: snippetId,
    );

    snippetController.setExample(sharedExample, descriptor: descriptor);

    return descriptor;
  }

  /// Creates an [ExamplesLoadingDescriptor] that can recover
  /// the current content.
  ExamplesLoadingDescriptor getLoadingDescriptor() {
    return ExamplesLoadingDescriptor(
      descriptors: _snippetEditingControllers.values
          .map(
            (controller) => controller.getLoadingDescriptor(),
          )
          .toList(growable: false),
      initialSdk: _sdk,
    );
  }

  late BeamShortcut runShortcut = BeamShortcut(
    shortcuts: LogicalKeySet(
      LogicalKeyboardKey.meta,
      LogicalKeyboardKey.enter,
    ),
    actionIntent: const RunIntent(),
    createAction: (BuildContext context) => CallbackAction(
      onInvoke: (_) => codeRunner.runCode(),
    ),
  );

  late BeamShortcut resetShortcut = BeamShortcut(
    shortcuts: LogicalKeySet(
      LogicalKeyboardKey.meta,
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.keyE,
    ),
    actionIntent: const ResetIntent(),
    createAction: (BuildContext context) => CallbackAction(
      onInvoke: (_) => reset(),
    ),
  );

  List<BeamShortcut> get shortcuts => [
        runShortcut,
        resetShortcut,
      ];

  @override
  void dispose() {
    super.dispose();
    codeRunner.removeListener(notifyListeners);
  }
}
