//
//  NSObject+ISKVOBlock.h
//  DemoKVOWithBlock
//
//  Created by iStig on 2018/5/29.
//  Copyright © 2018年 iStig. All rights reserved.
//

#import <Foundation/Foundation.h>

void PrintDescription(NSString *name, id obj);

typedef void (^ISObservingBlock)(id observedObject, NSString *observedKey, id oldValue, id newValue);

@interface NSObject (ISKVOBlock)

- (void)IS_addObserver:(id)observer
                forKey:(NSString *)key
             withBlock:(ISObservingBlock)block;

- (void)IS_removeObserver:(id)observer
                   forKey:(NSString *)key;

@end
