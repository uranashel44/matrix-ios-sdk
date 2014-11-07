/*
 Copyright 2014 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXRoom.h"

#import "MXSession.h"
#import "MXTools.h"

@interface MXRoom ()
{
    MXSession *mxSession;
    NSMutableArray *messages;
    NSMutableDictionary *stateEvents;
    NSMutableDictionary *members;
    
    // The token used to know from where to paginate back.
    NSString *pagEarliestToken;
    
    // The list of event listeners (`MXEventListener`) in this room
    NSMutableArray *eventListeners;

    /*
     Additional and optional metadata got from initialSync
     */
    MXMembership membership;
    
    // kMXRoomVisibilityPublic or kMXRoomVisibilityPrivate
    MXRoomVisibility visibility;
    
    // The ID of the user who invited the current user
    NSString *inviter;
}

@end

@implementation MXRoom

- (id)initWithRoomId:(NSString *)room_id andMatrixSession:(MXSession *)mxSession2
{
    return [self initWithRoomId:room_id andMatrixSession:mxSession2 andJSONData:nil];
}

- (id)initWithRoomId:(NSString *)room_id andMatrixSession:(MXSession *)mxSession2 andJSONData:(NSDictionary*)JSONData
{
    self = [super init];
    if (self)
    {
        mxSession = mxSession2;
        
        _room_id = room_id;
        messages = [NSMutableArray array];
        stateEvents = [NSMutableDictionary dictionary];
        members = [NSMutableDictionary dictionary];
        _canPaginate = YES;
        
        pagEarliestToken = @"END";
        
        eventListeners = [NSMutableArray array];
        
        // Store optional metadata
        if (JSONData)
        {
            if ([JSONData objectForKey:@"visibility"])
            {
                visibility = JSONData[@"visibility"];
            }
            if ([JSONData objectForKey:@"inviter"])
            {
                inviter = JSONData[@"inviter"];
            }
            if ([JSONData objectForKey:@"membership"])
            {
                membership = [MXTools membership:JSONData[@"membership"]];
            }
        }
    }
    return self;
}

#pragma mark - Properties getters implementation
- (NSArray *)messages
{
    return [messages copy];
}

- (MXEvent *)lastMessage
{
    return messages.lastObject;
}

- (NSArray *)stateEvents
{
    return [stateEvents allValues];
}

- (NSArray *)members
{
    return [members allValues];
}

- (NSDictionary *)powerLevels
{
    NSDictionary *powerLevels = nil;
    
    // Get it from the state events
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomPowerLevels];
    if (event && event.content)
    {
        powerLevels = [event.content copy];
    }
    return powerLevels;
}

- (BOOL)isPublic
{
    BOOL isPublic = NO;
    
    if (visibility)
    {
        // Check the visibility metadata
        if ([visibility isEqualToString:kMXRoomVisibilityPublic])
        {
            isPublic = YES;
        }
    }
    else
    {
        // Check this in the room state events
        MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomJoinRules];
        
        if (event && event.content)
        {
            NSString *join_rule = event.content[@"join_rule"];
            if ([join_rule isEqualToString:kMXRoomVisibilityPublic])
            {
                isPublic = YES;
            }
        }
    }
    
    return isPublic;
}

- (NSArray *)aliases
{
    NSArray *aliases;
    
    // Get it from the state events
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomAliases];
    if (event && event.content)
    {
        aliases = [event.content[@"aliases"] copy];
    }
    return aliases;
}

- (NSString *)displayname
{
    // Reuse the Synapse web client algo

    NSString *displayname;
    
    NSArray *aliases = self.aliases;
    NSString *alias;
    if (!displayname && aliases && 0 < aliases.count)
    {
        // If there is an alias, use it
        // TODO: only one alias is managed for now
        alias = [aliases[0] copy];
    }
    
    // Check it from the state events
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomName];
    if (event && event.content)
    {
        displayname = [event.content[@"name"] copy];
    }
    
    else if (alias)
    {
        displayname = alias;
    }
    
    // Try to rename 1:1 private rooms with the name of the its users
    else if ( NO == self.isPublic)
    {
        if (2 == members.count)
        {
            for (NSString *memberUserId in members.allKeys)
            {
                if (NO == [memberUserId isEqualToString:mxSession.matrixRestClient.credentials.userId])
                {
                    displayname = [self memberName:memberUserId];
                    break;
                }
            }
        }
        else if (1 >= members.count)
        {
            NSString *otherUserId;
            
            if (1 == members.allKeys.count && NO == [mxSession.matrixRestClient.credentials.userId isEqualToString:members.allKeys[0]])
            {
                otherUserId = members.allKeys[0];
            }
            else
            {
                if (inviter)
                {
                    // This is an invite
                    otherUserId = inviter;
                }
                else
                {
                    // This is a self chat
                    otherUserId = mxSession.matrixRestClient.credentials.userId;
                }
            }
            displayname = [self memberName:otherUserId];
        }
    }
    
    // Always show the alias in the room displayed name
    if (displayname && alias && NO == [displayname isEqualToString:alias])
    {
        displayname = [NSString stringWithFormat:@"%@ (%@)", displayname, alias];
    }
    
    if (!displayname)
    {
        displayname = [_room_id copy];
    }

    return displayname;
}

- (MXMembership)membership
{
    MXMembership result;
    
    // Find the uptodate value in room state events
    MXRoomMember *user = [self getMember:mxSession.matrixRestClient.credentials.userId];
    if (user)
    {
        result = user.membership;
    }
    else
    {
        result = membership;
    }
    
    return membership;
}

#pragma mark - Messages handling
- (void)handleMessages:(MXPaginationResponse*)roomMessages
              isLiveEvents:(BOOL)isLiveEvents
                 direction:(BOOL)direction
{
    NSArray *events = roomMessages.chunk;
    
    // Handles messages according to their time order
    if (direction)
    {
        // [MXRestClient messages] returns messages in reverse chronological order
        for (MXEvent *event in events) {
            [self handleMessage:event isLiveEvent:NO pagFrom:roomMessages.start];
        }
        
        // Store how far back we've paginated
        pagEarliestToken = roomMessages.end;
    }
    else {
        // InitialSync returns messages in chronological order
        for (NSInteger i = events.count - 1; i >= 0; i--)
        {
            MXEvent *event = events[i];
            [self handleMessage:event isLiveEvent:NO pagFrom:roomMessages.end];
        }
        
        // Store where to start pagination
        pagEarliestToken = roomMessages.start;
    }
    
    //NSLog(@"%@", messageEvents);
}

- (void)handleMessage:(MXEvent*)event isLiveEvent:(BOOL)isLiveEvent pagFrom:(NSString*)pagFrom
{
    // Put only expected messages into `messages`
    if (NSNotFound != [mxSession.eventsFilterForMessages indexOfObject:event.type])
    {
        if (isLiveEvent)
        {
            [messages addObject:event];
        }
        else
        {
            [messages insertObject:event atIndex:0];
        }
    }

    // Notify listener only for past events here
    // Live events are already notified from handleLiveEvent
    if (NO == isLiveEvent)
    {
        [self notifyListeners:event isLiveEvent:NO];
    }
}


#pragma mark - State events handling
- (void)handleStateEvents:(NSArray*)roomStateEvents
{
    NSArray *events = [MXEvent modelsFromJSON:roomStateEvents];
    
    for (MXEvent *event in events) {
        [self handleStateEvent:event];

        // Notify state events coming from initialSync
        [self notifyListeners:event isLiveEvent:NO];
    }
}

- (void)handleStateEvent:(MXEvent*)event
{
    switch (event.eventType)
    {
        case MXEventTypeRoomMember:
        {
            MXRoomMember *roomMember = [[MXRoomMember alloc] initWithMXEvent:event];
            members[roomMember.userId] = roomMember;
            
            break;
        }

        default:
            // Store other states into the stateEvents dictionary.
            // The latest value overwrite the previous one.
            stateEvents[event.type] = event;
            break;
    }
}


#pragma mark - Handle live event
- (void)handleLiveEvent:(MXEvent*)event
{
    if (event.isState)
    {
        [self handleStateEvent:event];
    }

    // Process the event
    [self handleMessage:event isLiveEvent:YES pagFrom:nil];

    // And notify the listeners
    [self notifyListeners:event isLiveEvent:YES];
}


- (void)paginateBackMessages:(NSUInteger)numItems
                     success:(void (^)(NSArray *messages))success
                     failure:(void (^)(NSError *error))failure
{
    // Event duplication management:
    // As we paginate from a token that corresponds to an event (the oldest one, ftr),
    // we will receive this event in the response. But we already have it.
    // So, ask for one more message, and do not take into account in the response the message
    // we already have
    if (![pagEarliestToken isEqualToString:@"END"])
    {
        numItems = numItems + 1;
    }
    
    // Paginate from last known token
    [mxSession.matrixRestClient messages:_room_id
                                  from:pagEarliestToken to:nil
                                 limit:numItems
                               success:^(MXPaginationResponse *paginatedResponse) {
        
        // Check pagination end
        if (paginatedResponse.chunk.count < numItems)
        {
            // We run out of items
            _canPaginate = NO;
        }
            
        // Event duplication management:
        // Remove the message we already have
        if (![pagEarliestToken isEqualToString:@"END"])
        {
            NSMutableArray *newChunk = [NSMutableArray arrayWithArray:paginatedResponse.chunk];
            [newChunk removeObjectAtIndex:0];
            paginatedResponse.chunk = newChunk;
        }
        
        // Process these new events
        [self handleMessages:paginatedResponse isLiveEvents:NO direction:YES];
                                   
        // Reorder events chronologically
        // And filter them: we want to provide only those which went to `messages`
        NSMutableArray *filteredChunk = [NSMutableArray array];
        if (paginatedResponse.chunk.count)
        {
            for (NSInteger i = paginatedResponse.chunk.count - 1; i >= 0; i--)
            {
                MXEvent *event = paginatedResponse.chunk[i];
                if (NSNotFound != [mxSession.eventsFilterForMessages indexOfObject:event.type])
                {
                    [filteredChunk addObject:event];
                }
            }
        }
                                   
        // Inform the method caller
        success(filteredChunk);
        
    } failure:^(NSError *error) {
        NSLog(@"paginateBackMessages error: %@", error);
        failure(error);
    }];
}

- (MXRoomMember*)getMember:(NSString *)user_id
{
    return members[user_id];
}

- (NSString*)memberName:(NSString*)user_id
{
    NSString *memberName;
    MXRoomMember *member = [self getMember:user_id];
    if (member)
    {
        if (member.displayname.length)
        {
            memberName = member.displayname;
        }
        else
        {
            memberName = member.userId;
        }
    }
    else
    {
        memberName = user_id;
    }
    return memberName;
}


#pragma mark - Events listeners
- (id)registerEventListenerForTypes:(NSArray*)types block:(MXRoomEventListenerBlock)listenerBlock
{
    MXEventListener *listener = [[MXEventListener alloc] initWithSender:self andEventTypes:types andListenerBlock:listenerBlock];
    
    [eventListeners addObject:listener];
    
    return listener;
}

- (void)unregisterListener:(id)listener
{
    [eventListeners removeObject:listener];
}

- (void)unregisterAllListeners
{
    [eventListeners removeAllObjects];
}

- (void)notifyListeners:(MXEvent*)event isLiveEvent:(BOOL)isLiveEvent
{
    // notifify all listeners
    for (MXEventListener *listener in eventListeners)
    {
        [listener notify:event isLiveEvent:isLiveEvent];
    }
}

@end
