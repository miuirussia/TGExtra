#!/usr/bin/env python3
"""Run the account lifecycle hook bodies against native Swift protocol fields."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/UI/AccountContextHooks.x').read_text()
chat = source.split('- (void)viewDidLoad {', 1)[1].split('%end', 1)[0].rsplit('}', 1)[0]
root = source.split('- (void)loadView {', 1)[1].split('%end', 1)[0].rsplit('}', 1)[0]
support = r'''
#import <Foundation/Foundation.h>
#import "ProfileBridge.h"
static id registeredContext;
static BOOL originalCalled;
@interface TLParser : NSObject
+ (void)registerMessageCleanupContext:(id)context;
@end
@implementation TLParser
+ (void)registerMessageCleanupContext:(id)context {
    NSCAssert(originalCalled, @"Register only after the host lifecycle method");
    registeredContext = context;
}
@end
id TestAccountContext(id controller, BOOL chat) {
    registeredContext = nil;
    originalCalled = NO;
    if (chat) TestChatContext(controller);
    else TestRootContext(controller);
    NSCAssert(originalCalled, @"Preserve the original lifecycle method");
    return registeredContext;
}
'''
swift = r'''
import Foundation
@_silgen_name("TestAccountContext") func register(_ controller: AnyObject, _ chat: Bool) -> AnyObject?
enum HostAccountReader {
    static func account(in value: Any) -> String? { nil }
}
enum PeerInfoStore {
    static func rememberOwnUserId(_ id: Int64, account: String) {}
    static func ownUserId(for account: String) -> NSNumber? { nil }
}
enum RenderedMessageReader {
    static func peerKey(fromPeerId value: Any) -> Int64? { nil }
}
private struct Account { let peerId: Int64 }
private protocol AccountContext: AnyObject { var account: Account { get } }
private final class Context: AccountContext {
    let account: Account
    init(_ id: Int64) { account = Account(peerId: id) }
}
private class Controller: NSObject {
    private let context: AccountContext
    init(_ context: AccountContext) { self.context = context }
}
private final class ChildController: Controller {}
let defaults = UserDefaults.standard
let savedId = defaults.object(forKey: "TGExtraLastKnownUserId")
defer { defaults.set(savedId, forKey: "TGExtraLastKnownUserId") }
for chat in [false, true] {
    for id in [Int64(101), 202] {
        let context = Context(id)
        let controller = ChildController(context)
        precondition(!controller.responds(to: NSSelectorFromString("context")))
        let registered = register(controller, chat)
        precondition(registered === context, "Register the controller's native Swift account context")
        precondition(ProfileBridge.sharedContext === context, "Keep the same context for profile lookups")
        if chat {
            precondition(defaults.integer(forKey: "TGExtraLastKnownUserId") == id,
                         "Refresh the current user when switching accounts")
        }
    }
    precondition(register(NSObject(), chat) == nil, "Unknown controllers have no account to register")
}
ProfileBridge.sharedContext = nil
print("PASS account hooks: native Swift protocol context, inheritance, account switching, lifecycle ordering and missing fields")
'''
with tempfile.TemporaryDirectory(prefix='tgextra-account-context-') as directory:
    work = Path(directory)
    harness = work / 'hooks.m'
    functions = ''.join('static void ' + name + '(id self) {' +
                        body.replace('%orig;', 'originalCalled = YES;') + '}\n'
                        for name, body in [('TestChatContext', chat), ('TestRootContext', root)])
    harness.write_text(support.replace('id TestAccountContext(', functions + 'id TestAccountContext('))
    main = work / 'main.swift'
    main.write_text(swift)
    obj = work / 'hooks.o'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-I' + str(ROOT / 'Sources/tgapi/UI'),
                    '-c', str(harness), '-o', str(obj)], check=True)
    for optimization in ['-Onone', '-O']:
        binary = work / 'tests'
        subprocess.run(['swiftc', optimization, str(ROOT / 'Sources/tgapi/HostValueReader.swift'),
                        str(ROOT / 'Sources/tgapi/UI/ProfileBridge.swift'), str(main), str(obj),
                        '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
