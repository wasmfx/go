package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Generate some numbers. (As it happens, the ones from 0..n.)
// Send them on the given channel.
func generator(c chan int32, n int32) {
	for i := int32(0); i < n; i++ {
		c <- i
	}
	close(c)
}

// Sum up the numbers sent on the given channcel.
func summer(c chan int32) int32 {
	result := int32(0)
	for {
		p, more := <-c
		if !more {
			break
		}
		result += p
	}
	return result
}

func runsum(n int32) {
	c := make(chan int32)
	go generator(c, n)
	result := summer(c)
	fmt.Println("Result: ", result)
}

func main() {
	first, err := strconv.Atoi(os.Args[1])
	if err != nil {
		panic("arg not parsed as int32")
	}
	last, err := strconv.Atoi(os.Args[2])
	if err != nil {
		panic("arg not parsed as int32")
	}

	increment := 1000
	if len(os.Args) == 4 {
		increment, err = strconv.Atoi(os.Args[3])
		if err != nil {
			panic("arg not parsed as int32")
		}
	}

	for i := int32(first); i <= int32(last); i += int32(increment) {
		start := time.Now()
		runsum(i)
		fmt.Println("Benchmark size: ", i)
		fmt.Println("Time: ", time.Since(start))
	}
}

// ok:wq
