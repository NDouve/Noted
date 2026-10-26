// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The driver for running perf_benchmark.dart in profile mode:
//
//     flutter drive --driver=integration_test/perf_driver.dart \
//         --target=integration_test/perf_benchmark.dart -d windows --profile

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
