.pragma library

// Incremental reconcile for the host Instantiator. Reassigning its model array
// rebuilds every delegate, and a rebuilt poller orphans that host's pots (#8).
// Removals come back descending so applying them in order cannot shift a later
// index.
function diff(current, want) {
    var remove = []
    for (var i = current.length - 1; i >= 0; i--)
        if (want.indexOf(current[i]) === -1) remove.push(i)

    var add = []
    for (var j = 0; j < want.length; j++)
        if (current.indexOf(want[j]) === -1) add.push(want[j])

    return {remove: remove, add: add}
}
