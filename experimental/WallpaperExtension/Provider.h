#import <Foundation/Foundation.h>
BOOL FSConfigureConnection(NSXPCConnection *connection);
int FSProviderSelfTest(void);

void FSConfigureInterface(NSXPCInterface *interface);

NSDictionary *FSInspectSnapshot(id snapshot);

NSDictionary *FSInspectSettings(id settings);
NSDictionary *FSSettingsModel(void);
// Test/host adapter: files are passed as real security-scoped URL wrappers.
id FSCreateRequest(NSDictionary *creation, NSArray<NSURL *> *files);
NSDictionary *FSInspectCreation(id request);
