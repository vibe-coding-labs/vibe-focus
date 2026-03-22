import { registerRoot, Composition } from 'remotion';
import { FocusToMainDisplay } from './FocusToMainDisplay';
import { RestoreOriginalLayout } from './RestoreOriginalLayout';
import { PermissionsDiagnostics } from './PermissionsDiagnostics';
import { HeroMultiWindowDemo } from './HeroMultiWindowDemo';
import { HeroMultiWindowDemoWithAudio } from './HeroMultiWindowDemoWithAudio';

const RemotionRoot: React.FC = () => {
  return (
    <>
      {/* Hero Multi-Window Demo - MP4 (1280x720, 15 seconds, 60fps) */}
      <Composition
        id="HeroMultiWindowDemo"
        component={HeroMultiWindowDemo}
        width={1280}
        height={720}
        fps={60}
        durationInFrames={900}
        defaultProps={{}}
      />

      {/* Hero Multi-Window Demo with Audio and Text - MP4 (1280x720, 15 seconds, 60fps) */}
      <Composition
        id="HeroMultiWindowDemoWithAudio"
        component={HeroMultiWindowDemoWithAudio}
        width={1280}
        height={720}
        fps={60}
        durationInFrames={900}
        defaultProps={{}}
      />

      {/* Focus to Main Display - GIF (800x600, 6 seconds, 30fps) */}
      <Composition
        id="FocusToMainDisplay"
        component={FocusToMainDisplay}
        width={800}
        height={600}
        fps={30}
        durationInFrames={180}
        defaultProps={{}}
      />

      {/* Restore Original Layout - MP4 (1200x800, 10 seconds, 60fps) */}
      <Composition
        id="RestoreOriginalLayout"
        component={RestoreOriginalLayout}
        width={1200}
        height={800}
        fps={60}
        durationInFrames={600}
        defaultProps={{}}
      />

      {/* Permissions Diagnostics - MP4 (1200x900, 12 seconds, 30fps) */}
      <Composition
        id="PermissionsDiagnostics"
        component={PermissionsDiagnostics}
        width={1200}
        height={900}
        fps={30}
        durationInFrames={360}
        defaultProps={{}}
      />
    </>
  );
};

registerRoot(RemotionRoot);
