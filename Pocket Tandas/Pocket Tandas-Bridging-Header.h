// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  Pocket Tandas-Bridging-Header.h
//  Pocket Tandas
//
//  The app is Swift throughout except for the two disc-restoration DSP cores,
//  which are C++ carried over verbatim from the offline tools they were measured
//  in. This is the only thing they are reached through.
//

#import "DSP/PTRestorationDSP.h"
