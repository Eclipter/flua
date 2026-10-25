#import <Foundation/Foundation.h>

NSDictionary *FSPlaybackEnvironment(void);
NSDictionary *FSPlaybackPowerEnvironment(void);
BOOL FSPlaybackPowerEnabled(NSDictionary *policy);
BOOL FSPlaybackFullscreenEnabled(NSDictionary *policy);
NSArray<NSString *> *FSFullscreenDisplays(void);
BOOL FSPlaybackShouldPause(NSDictionary *policy, NSDictionary *environment, NSNumber *displayID,
                           NSString *presentation, BOOL preview, BOOL hostSuspended);
BOOL FSPlaybackPolicySelfTest(void);
