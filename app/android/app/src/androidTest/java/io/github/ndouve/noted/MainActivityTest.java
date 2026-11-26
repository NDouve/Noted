// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package io.github.ndouve.noted;

import android.os.Bundle;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.rule.ActivityTestRule;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.junit.Rule;
import org.junit.runner.RunWith;

/**
 * Runs integration_test/android/first_launch_save_test.dart on a device or emulator, by
 * `adb shell am instrument -w -e phase <probe|write|check> -e run <id> ...`. The app is built once
 * and stays installed between phases, so the data a phase saves is still there for the next.
 *
 * <p>FlutterTestRunner builds this class (so the constructor runs) before it launches the
 * activity, which is when the phase is written for the Dart test: `<cache>/noted-test-phase`, two
 * lines (the phase, the run id). The Dart test reads the file and deletes it.
 */
@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
  @Rule
  public ActivityTestRule<MainActivity> rule = new ActivityTestRule<>(MainActivity.class, true, false);

  public MainActivityTest() {
    Bundle args = InstrumentationRegistry.getArguments();
    String phase = args.getString("phase", "");
    String run = args.getString("run", "local");
    File cache = InstrumentationRegistry.getInstrumentation().getTargetContext().getCacheDir();
    File file = new File(cache, "noted-test-phase");
    try (FileOutputStream out = new FileOutputStream(file)) {
      out.write((phase + "\n" + run + "\n").getBytes(StandardCharsets.UTF_8));
    } catch (IOException e) {
      throw new RuntimeException("Could not write the phase file " + file, e);
    }
  }
}
