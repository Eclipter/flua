#import <Foundation/Foundation.h>

NSDictionary *FSPlaybackEnvironment(void);
BOOL FSPlaybackShouldPause(NSDictionary *policy, NSDictionary *environment, NSNumber *displayID,
                           NSString *presentation, BOOL preview, BOOL hostSuspended);
BOOL FSPlaybackPolicySelfTest(void);
